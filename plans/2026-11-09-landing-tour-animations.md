# Landing Tour Animations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four new looping APNG scenes for the landing tour (Alerts, Out of limit, Closed-Lid, Your week), made by `make screenshots`, and the tour reordered with new texts.

**Architecture:** A pure, generic scene timeline (named phases → frames, a pointer track with clicks) drives every new scene through the existing recorder (`ScreenshotRenderer.writeAnimation`, `APNGWriter`). Scenes compose real app views (notch, alerts, recap card, popover row) with **snapshots of real windows** (Chats, Statistics; captured once through the existing titled-window path into an in-memory image) and two drawn views (Terminal, MacBook). Everything lives in the test target.

**Tech Stack:** Swift 6, SwiftUI/AppKit offscreen rendering, ImageIO APNG, Swift Testing; static HTML.

**Spec:** `specs/2026-11-09-landing-tour-animations-design.md`

## Global Constraints

- Test target only (`WorkdeckTests/Screenshots/`); no product code changes. Demo/fixture data only.
- Every scene: APNG at 2×, loop count 0, first frame == last frame, clear canvas, dark appearance, under 5 MB before `oxipng` (aim ~4 MB after).
- Rendering only with the screenshots switch (`@Test(.enabled(if: ScreenshotRenderer.isEnabled))`); pure timeline tests run always.
- Pointer: `NSCursor.arrow.image` at its hot spot; a click dips it to scale 0.9 for ~0.15 s.
- File names: `alert-session-animated.png`, `alert-session.png`, `switch-account-animated.png`, `closed-lid-animated.png`, `closed-lid.png`, `week-animated.png`.
- Second account in Out of limit: **personal** (Chats fixture). Session: **orbit-app**. Chat: **"Fix the orbit renderer"** (main).
- **One animation at a time:** each task ends with `make screenshots`, frames shown to the user, and a stop until the user says it is fine ("норм"). Their remarks are fixed inside the same task before the next starts.
- `make screenshots` rewrites every image; keep only the files the task changes (`git checkout --` the rest; `notch-expanded.png` changes every run).
- No commits until the user says "commit"; stage only.
- Suite run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

- **The loop seam with live content** (a spinner or countdown still moving on the last frame): the last frame must equal the first. Pinned per scene by `expectAnimation` (first == last pixels) and by each scene ending on a one-frame compact hold.
- **The click lands on the control it presses** (alert, chat row's Terminal button, account row, Details…, the popover switch): pinned by each scene's `…PointerTargetsAreInsideTheCanvas` test and checked by eye at the user gate.
- **File size** of the scroll and window scenes (large changed rectangles): pinned by `expectAnimation`'s 5 MB check; if exceeded, cut transition fps to 30 and shorten holds.
- **Reduced motion** on the page shows the right still for each tab: checked in Task 5 by reading the `<picture>` sources.
- **A window snapshot drawn at the wrong scale** (1× in a 2× canvas looks blurry): pinned by `theWindowSnapshotIsTwiceItsPointSize`.

---

### Task 1: Scene machinery, drawn Terminal, and the Alerts scene

**Files:**
- Create: `WorkdeckTests/Screenshots/SceneTimeline.swift` (pure: `ScenePhase`, `SceneFrame`, `SceneTimeline`, `PointerTrack`)
- Create: `WorkdeckTests/Screenshots/SceneTimelineTests.swift`
- Create: `WorkdeckTests/Screenshots/DrawnTerminal.swift`
- Create: `WorkdeckTests/Screenshots/AlertSessionAnimation.swift`
- Modify: `WorkdeckTests/Screenshots/ScreenshotRenderer.swift` (window snapshot to memory)
- Modify: `WorkdeckTests/Screenshots/ScreenshotTests.swift` (new tests, `everyImageWasWritten`)

**Interfaces:**
- Produces:
  ```swift
  nonisolated struct ScenePhase: Equatable, Sendable {
      enum Sampling: Equatable, Sendable { case hold, transition, live }
      var name: String; var duration: TimeInterval; var sampling: Sampling
      static func hold(_ name: String, _ d: TimeInterval) -> ScenePhase      // one frame
      static func transition(_ name: String, _ d: TimeInterval) -> ScenePhase // 60 fps, not live
      static func live(_ name: String, _ d: TimeInterval) -> ScenePhase       // 60 fps, live
  }
  nonisolated struct SceneFrame: Equatable, RecordedFrame {
      var time: TimeInterval; var delay: TimeInterval; var isLive: Bool
      var phase: String
      /// 0…1 through the phase, at the frame's start (eased by the scene where it wants).
      var progress: Double
  }
  nonisolated enum SceneTimeline {
      static func frames(_ phases: [ScenePhase], transitionRate: Double = 60) -> [SceneFrame]
      static func length(_ phases: [ScenePhase]) -> TimeInterval
      /// Start time of the first phase named `name`.
      static func start(of name: String, in phases: [ScenePhase]) -> TimeInterval?
  }
  nonisolated struct PointerTrack: Equatable, Sendable {
      struct Key: Equatable, Sendable { var time: TimeInterval; var point: CGPoint?; var click: Bool = false }
      init(_ keys: [Key])
      /// Eased (`NotchAnimationTimeline.eased`) between keys; nil while hidden (a key with `point: nil`).
      func point(at time: TimeInterval) -> CGPoint?
      /// 1 normally, 0.9 at the bottom of a click's dip (0.15 s centered on the click key's time).
      func scale(at time: TimeInterval) -> Double
  }
  extension ScreenshotRenderer {
      /// The window as `writeWindow` frames it (title bar, toolbar, corners, shadow), kept in memory at 2×.
      static func snapshotWindow<V: View>(_ view: V, title: String, size: CGSize, dark: Bool) throws -> CGImage
  }
  struct DrawnTerminal: View {
      static let titleBarHeight: CGFloat = 28
      let title: String
      /// Each line's text and whether it is the agent's (drawn with the Claude accent mark `⏺`).
      let lines: [DrawnTerminal.Line]
      struct Line: Hashable { var text: String; var isAgent = false; var isPrompt = false }
  }
  ```
  `snapshotWindow` reuses `openWindow`/`capture`/`framed`: split `capture` so the framed `NSBitmapImageRep` is returned before `save`; `writeWindow` keeps its behavior.

- [ ] **Step 1: Write the failing timeline tests** (`SceneTimelineTests`)
  - `aHoldIsOneFrameWithItsWholeDelay`: `[.hold("a", 1)]` → one frame, delay 1, progress 0, not live.
  - `transitionsAreSampledAt60AndEndOnTheirLength`: `[.transition("t", 0.5)]` → 30 frames; delays sum to 0.5; progress rises 0 → < 1; `[.live("l", 0.2)]` frames are `isLive`.
  - `phasesFollowEachOther`: `[.hold("a", 1), .transition("b", 0.5)]` → second phase's first frame `time == 1`; `start(of: "b") == 1`; `length == 1.5`.
  - `thePointerEasesBetweenKeysAndHides`: keys `(0, (0,0))`, `(1, (100,0))`, `(2, nil)` → `point(at: 0.5).x == 50` (smoothstep midpoint), `point(at: 0.25).x < 25`, `point(at: 2.5) == nil`.
  - `aClickDipsThePointer`: key at 1 with `click: true` → `scale(at: 1) == 0.9`, `scale(at: 0.8) == 1`, `scale(at: 1.2) == 1`.
- [ ] **Step 2: Run** `-only-testing:WorkdeckTests/SceneTimelineTests`. Expected: build fails (types missing).
- [ ] **Step 3: Implement `SceneTimeline.swift`.** Sampling as `NotchAnimationTimeline.samples` (last frame trimmed to the phase end); a key with `point: nil` hides the pointer from its time on; between two shown keys the point is eased by the elapsed fraction.
- [ ] **Step 4: Run.** Expected: pass.
- [ ] **Step 5: `snapshotWindow` + `DrawnTerminal`.** Test (switch-gated) `theWindowSnapshotIsTwiceItsPointSize`: snapshot `ChatsWindow` at 640×520 → `image.width == Int((640 + 2 * windowMargin) * 2)`. `DrawnTerminal`: rounded rect (radius 12), `#1E1E1E` body, title bar `#2A2A2A` with red/yellow/green 12 pt dots and the centered title (13 pt, secondary), lines in `.system(size: 13, design: .monospaced)` light gray; agent lines start with `⏺` tinted like the Claude icon (the app's Claude accent color, as `AgentIcon` uses); a prompt line `>` followed by a block caret; shadow as windows (`radius 30, y 12, black 0.55`).
- [ ] **Step 6: The Alerts scene** in `AlertSessionAnimation.swift` (spec §3.1). Phases (starting point): `hold("compact", 1)`, `transition("open", 0.4)`, `live("alert", 1.2)`, `transition("pointerIn", 0.6)`, `live("press", 0.4)`, `transition("close", 0.4)`, `transition("terminalIn", 0.35)`, `hold("terminal", 2.0)`, `transition("terminalOut", 0.35)`, `hold("compact", 0.5)`. The alert is `fixtures.demoNotch(elapsed: 42)`'s `.sessionFinished` alert (demo second 42, `orbit-app`; `#require` it). Notch drawn with `NotchTransitionView` (open/close progress from `NotchAnimationTimeline.openingProgress/closingProgress` at the phase's time); its expanded size measured like `NotchAnimation.alertExpandedSize`. The pointer is drawn by the scene view from a `PointerTrack` (enters from the lower right during `pointerIn`, clicks the alert's middle at the start of `press`, hides when the Terminal is in). Terminal: `DrawnTerminal(title: "orbit-app — claude", lines: [agent "Done. The orbit renderer now batches its draw calls;", "all 48 tests pass.", prompt])` centered under the notch, fading in with a 12 pt upward slide; fading out the same way. Canvas: wide enough for the Terminal (about 560 pt wide) plus `NotchTransitionView.margin`, tall enough for notch + gap 24 + Terminal + margin. Still `alert-session.png`: as `notchAlert()` but with the finished alert.
- [ ] **Step 7: Tests in `ScreenshotTests`** (switch-gated): `alertSessionAnimation` → `expectAnimation(url, canvas:)`; `alertSessionStill` → written at 2×. Always-run: `alertSessionPointerTargetsAreInsideTheCanvas` (the track's points at the click times lie inside the canvas and inside the expanded alert's rect). Add both names to `everyImageWasWritten`.
- [ ] **Step 8: Run** `-only-testing:WorkdeckTests/SceneTimelineTests -only-testing:WorkdeckTests/ScreenshotTests`. Expected: pass.
- [ ] **Step 9: Render and show.** `make screenshots`; restore unrelated images; extract 6–8 frames with `ffmpeg` into the scratchpad and look at them; then show the user the frames (or the file) and **stop until the user says it is fine.** Apply their remarks, re-render, show again.
- [ ] **Step 10: Stage.**

### Task 2: The Out of limit scene

**Files:**
- Create: `WorkdeckTests/Screenshots/SwitchAccountAnimation.swift`
- Modify: `WorkdeckTests/Screenshots/ScreenshotTests.swift`

**Interfaces:**
- Consumes: `SceneTimeline`, `PointerTrack`, `snapshotWindow`, `DrawnTerminal` (Task 1); `fixtures.chats()`.
- Produces: `SwitchAccountAnimation` with `canvas`, `phases`, `pointer: PointerTrack`, `write() async throws -> URL`.

- [ ] **Step 1: Snapshot and geometry.** `snapshotWindow(ChatsWindow(controller: fixtures.chats()), title: "Claude Code Chats", size: 640×520, dark: true)`. The row "Fix the orbit renderer" and its right edge (where the real row shows **Terminal** on hover) are constants measured from that image (`chatRow: CGRect` in window points), checked by eye. The hover button and the account chooser cannot be forced offscreen (row `@State`, private `AccountChooser`): draw look-alikes over the snapshot — a bordered "Terminal" button at the row's right, and a popover under it ("Open in Terminal as", rows "● main" and "● personal" with purple dot, the hovered row with the accent at 15 %) as `AccountChooser` draws them (spec §3.2 allows this).
- [ ] **Step 2: Alert.** `.threshold(window, threshold: 95, account: "main")` with the 5-hour `UsageWindow` from `fixtures.demoNotch(elapsed: 30)`'s state, set to 95 % used if the state's window must match (builder: whatever the alert view needs to read "5-hour limit at 95% · main"; check by eye).
- [ ] **Step 3: Phases** (starting point, ~12 s): `hold("compact",1)`, `transition("open",0.4)`, `live("alert",1.0)`, `transition("pointerToAlert",0.5)`, `live("pressAlert",0.3)`, `transition("close",0.4)`, `transition("chatsIn",0.35)`, `transition("pointerToRow",0.8)`, `hold("hover",0.4)`, `transition("pressTerminal",0.3)`, `hold("chooser",0.5)`, `transition("pointerToPersonal",0.4)`, `transition("pressPersonal",0.3)`, `transition("terminalIn",0.4)`, `hold("terminal",2.4)`, `transition("allOut",0.4)`, `hold("compact",0.5)`. Chats sits under the notch, steps back (scale 0.96, dim 30 %) as the Terminal comes in front, offset down-right by 40 pt. Terminal lines: `"$ claude --resume"`, agent `"Picking up where we left off: the renderer still"`, `"redraws every frame. Batching the draw calls next."`, prompt. Title `"orbit-app — claude (personal)"`.
- [ ] **Step 4: Tests:** always-run `switchAccountPointerTargetsAreInsideTheCanvas` (clicks fall inside: the alert rect, the Terminal button rect, the personal row rect); switch-gated `switchAccountAnimation` → `expectAnimation`. Add to `everyImageWasWritten`.
- [ ] **Step 5: Run** the two suites. Expected: pass.
- [ ] **Step 6: Render and show; stop until the user says it is fine.** As Task 1 Step 9.
- [ ] **Step 7: Stage.**

### Task 3: Drawn MacBook and the Closed-Lid scene

**Files:**
- Create: `WorkdeckTests/Screenshots/DrawnMacBook.swift`
- Create: `WorkdeckTests/Screenshots/ClosedLidAnimation.swift`
- Modify: `WorkdeckTests/Screenshots/ScreenshotTests.swift`

**Interfaces:**
- Consumes: Task 1 types; `fixtures.closedLidMode()`, `fixtures.claudeCode()`, `fixtures.demoNotch(elapsed:)`, `ClosedLidModeRow`, `NotchTransitionView`.
- Produces:
  ```swift
  struct DrawnMacBook<Screen: View>: View {
      static var screenSize: CGSize { get }   // the screen area in points, 16:10
      let lidOpen: Double                      // 1 open … 0 closed
      @ViewBuilder let screen: () -> Screen
  }
  nonisolated enum ClosedLidClock {
      /// "12:00" at the lid closing's start … "12:40" at the opening's end, minute steps, linear.
      static func text(at progress: Double) -> String
  }
  ```

- [ ] **Step 1: Failing test** `theClockRunsFromNoonTo1240`: `text(at: 0) == "12:00"`, `text(at: 0.5) == "12:20"`, `text(at: 1) == "12:40"`. Run, expect build failure; implement; run, expect pass.
- [ ] **Step 2: `DrawnMacBook`.** Screen 400×250 pt in a dark bezel (`#1B1B1D`, 10 pt, top radius 14) with a notch (`NotchGeometry.housing` scaled to the screen); base 460×12 below with a center lip; neutral grays, no logo. `lidOpen` scales the bezel+screen vertically toward its bottom edge (`scaleEffect(y: max(0.02, lidOpen), anchor: .bottom)`) and darkens it (`brightness(-0.6 × (1 − lidOpen))`).
- [ ] **Step 3: Screen content.** A desktop gradient; a 22 pt menu bar with the Workdeck menu bar label (`MenuBarLabel` from the popover test) and the clock; under it the popover's Closed-Lid Mode row (`ClosedLidModeRow` over `fixtures.closedLidMode()`, switch starting off, turning on at the click) in a popover-like rounded panel; the notch at the screen's top drawn with the compact demo notch (spinner live) and later expanded on hover (`NotchTransitionView`, scaled to the screen). After the lid opens, the expanded notch shows the demo at a second where `orbit-app` has finished (its alert second 42 or later; check that the session row reads finished).
- [ ] **Step 4: Phases** (~10 s): `hold("on",0.6)`, `transition("pointerToSwitch",0.6)`, `transition("pressSwitch",0.3)`, `live("working",1.0)`, `transition("lidClose",0.7)`, `transition("time",1.6)` (clock 12:00 → 12:40 beside the laptop, 34 pt, secondary), `transition("lidOpen",0.7)`, `transition("pointerToNotch",0.5)`, `transition("open",0.4)`, `live("finished",2.0)`, `transition("close",0.4)`, `transition("reset",0.4)` (popover and switch back to the first frame's look), `hold("on",0.4)`. The first and last frames: lid open, popover open, switch off, pointer hidden.
- [ ] **Step 5: Still `closed-lid.png`:** the scene view at the moment after the click (switch on), written with `ScreenshotRenderer.write`.
- [ ] **Step 6: Tests:** always-run `closedLidPointerTargetsAreInsideTheScreen`; switch-gated `closedLidAnimation` (`expectAnimation`) and `closedLidStill`. Add both names to `everyImageWasWritten`.
- [ ] **Step 7: Run** suites. Expected: pass.
- [ ] **Step 8: Render and show; stop until the user says it is fine.**
- [ ] **Step 9: Stage.**

### Task 4: The Your week scene

**Files:**
- Create: `WorkdeckTests/Screenshots/WeekAnimation.swift`
- Modify: `WorkdeckTests/Screenshots/ScreenshotTests.swift`

**Interfaces:**
- Consumes: Task 1 types; `RecapDemoScript.recap(now:calendar:)`, `fixtures.statistics()`, `StatisticsWindow`, `ActivityGrid` (pure geometry: columns, cell size, spacing).
- Produces: `WeekAnimation` with `canvas`, `phases`, `pointer`, `write()`; pure `GridReveal.columns(at progress: Double, total: Int) -> Int` (0 at 0, `total` at 1, rounded up, monotonic).

- [ ] **Step 1: Failing test** `theGridRevealsColumnByColumn`: `columns(at: 0, total: 27) == 0`, `columns(at: 1, total: 27) == 27`, `columns(at: 0.5, total: 27) == 14`, monotonic over 0…1. Run (build fails), implement, run (pass).
- [ ] **Step 2: Snapshots.** `snapshotWindow(StatisticsWindow(controller:), title: "Statistics", size: CGSize(width: 460, height: H), dark: true)` with H = the content's full height (measure the scroll content's fitting height; the window then shows everything without scrolling). Second snapshot of the same window with the grid empty: a controller over the same fixture but no recorded days (builder: an empty `RecapStore` in the fixture's temporary folder), same H, so labels and layout match. The grid's rect and column pitch come from `ActivityGrid`'s geometry plus the grid's origin measured in the snapshot (constants, checked by eye).
- [ ] **Step 3: Scene.** The viewport shows the window at 460×680 like the real default: the snapshot's top band (title bar + toolbar, `toolbarHeight` measured) stays fixed; the band under it is the snapshot's body clipped to the viewport and offset by the scroll. Grid fill: draw the empty snapshot, then the full snapshot clipped to the grid's first `GridReveal.columns` columns. The recap card is `LimitsExpandedView` with `model.recap` set as `notchRecap()` does, inside `NotchTransitionView`; the pointer clicks **Details…** (its rect measured on the card).
- [ ] **Step 4: Phases** (~12 s): `hold("compact",0.8)`, `transition("open",0.4)`, `hold("card",1.2)`, `transition("pointerToDetails",0.6)`, `transition("pressDetails",0.3)`, `transition("close",0.4)`, `transition("windowIn",0.35)`, `transition("grid",1.0)`, `hold("top",0.6)`, `transition("scroll",5.0)` at 30 fps (`transitionRate: 30` for this phase if size requires), `hold("bottom",1.0)`, `transition("windowOut",0.35)`, `hold("compact",0.5)`. Scroll eased with `NotchAnimationTimeline.eased`.
- [ ] **Step 5: Tests:** always-run `weekPointerTargetsDetails`; switch-gated `weekAnimation` (`expectAnimation`). Add the name to `everyImageWasWritten`.
- [ ] **Step 6: Run** suites. Expected: pass.
- [ ] **Step 7: Render and show; stop until the user says it is fine.**
- [ ] **Step 8: Stage.**

### Task 5: The page and docs

**Files:**
- Modify: `site/index.html`
- Modify: `CLAUDE.md` (screenshots entry: the four scenes, `SceneTimeline`, `PointerTrack`, `DrawnTerminal`, `DrawnMacBook`, window snapshots)
- Modify: `specs/2026-11-09-landing-tour-animations-design.md` (Status: Implemented; rulings from the user gates)

- [ ] **Step 1: Tabs.** Reorder and retitle per spec §2 (ids `tab-0…6` / `slide-0…6` renumbered in the new order, `aria-controls`/`aria-labelledby` matching). New texts verbatim from spec §2. `data-seconds` per animated tab = `ceil(SceneTimeline.length(phases))` of its scene (print the lengths from a test run and copy them).
- [ ] **Step 2: Slides.** Tab 2: `<picture><source media="(prefers-reduced-motion: reduce)" srcset="screenshots/alert-session.png"><img src="screenshots/alert-session.png" data-animated="screenshots/alert-session-animated.png" …>`, class `slide top`. Tab 3: reduced-motion and default `src` the Chats stills (`chats-dark.png` under `prefers-color-scheme: dark`, `chats-light.png` otherwise) with `data-animated="screenshots/switch-account-animated.png"`, class `slide top`. Tab 4: `closed-lid.png` + `closed-lid-animated.png`. Tab 6: statistics stills + `week-animated.png`, class `slide top`. Tab 7: Instances as now. Alt texts describe the animation (one sentence each).
- [ ] **Step 3: Check** `python3 -I scripts/release/test_install.py` passes; open `site/index.html` in the browser through `file://` (or `python3 -m http.server` in `_site` built like `pages.yml`) and click through the seven tabs; with reduced motion simulated, each tab shows its still.
- [ ] **Step 4: Full suite** `xcodebuild -scheme Workdeck -destination 'platform=macOS' test …`. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Show the user the whole tour; stage;** commit only on "commit": `docs(site): animate the alerts, accounts, lid and recap tabs`.
