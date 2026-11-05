# Animated Notch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make screenshots` also writes two looping APNG animations of the notch (hover, alert), and the landing page's first two tabs and the README show them.

**Architecture:** A pure timeline type turns a list of phases into frames (delay, progress, pointer, live or not). A recorder keeps one offscreen window up for a whole animation, updates an observable state per frame, waits real time on live frames so the notch's own motion advances, captures each frame and writes them with ImageIO as an APNG. A SwiftUI view draws the notch between compact and expanded by progress, imitating DynamicNotchKit. All in the test target; no product code changes.

**Tech Stack:** Swift Testing, SwiftUI/AppKit offscreen rendering, SwiftUI `Spring`, ImageIO (APNG), static HTML.

**Spec:** `specs/2026-11-05-notch-animations-design.md`

## Global Constraints

- Files: `docs/media/screenshots/notch-hover-animated.png`, `docs/media/screenshots/notch-alert-animated.png` (APNG with a `.png` extension), 2× pixels, loop count 0.
- Phases (spec §2): hover `compact 1 s → pointer in 0.6 s → open 0.4 s → expanded 3.5 s → pointer out 0.4 s → close 0.4 s → compact 0.5 s`; alert `compact 1 s → open 0.4 s → expanded 2.5 s → close 0.4 s → flash 1.5 s → compact 0.5 s`.
- Opening `Spring.bouncy(duration: 0.4)`, closing `Spring.smooth(duration: 0.4)`, sampled at 30 fps; live phases (expanded, pointer out, flash) at 10 fps (0.1 s); a compact hold is one frame.
- Transition (spec §3.1): outline size and radii lerp compact (radii 6/14) → expanded (15/20) by progress (unclamped, overshoot allowed); expanded content blur `10 × (1 − p)`, y-scale `0.6 + 0.4 × p` anchored top, opacity `p`; compact halves blur `10 × p`, x-scale `1 − p`, opacity `1 − p`.
- Data: expanded content from `ScreenshotFixtures.demoNotch(elapsed:)` from demo second 12, advancing one demo second per real second; alert as `notch-alert.png` (demo second 30, threshold alert); compact at both ends of the alert loop is the second-30 state.
- Pointer: `NSCursor.arrow.image`, its hot spot on the compact notch's middle while resting; no pointer in the alert animation.
- Each file under 5 MB (target 4 MB).
- Without `WORKDECK_SCREENSHOTS=1` nothing renders or writes (same switch as the stills). No product code changes.
- Landing: `<picture>` with `(prefers-reduced-motion: reduce)` → the still.
- No commits until the user says "коммить". Suite alone: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/<Suite> 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; with rendering: `make screenshots`.

## Review Focus

- **The opening overshoot clipped by the canvas** (the bouncy spring grows the outline past the expanded size): the canvas must fit `expandedSize × max opening progress`. Pinned in Task 3 by `theCanvasFitsTheOvershoot`.
- **Browsers without APNG show the first frame:** it must be the compact notch with no pointer. Pinned in Task 1 by `theLoopIsSeamless` (first frame progress 0, pointer nil).
- **Slow rendering stretching live frames:** the file's delays must be the timeline's (0.1 s), not the measured capture time. Pinned in Task 2 by `delaysAreWrittenAsGiven` and in Task 3 by passing frame delays straight through.
- **Reduced motion on the landing page:** the still must be offered. Pinned in Task 4 by `test_animations_have_a_still_for_reduced_motion`.
- **The pointer's tip, not its image corner, on the notch:** pinned in Task 3 by positioning with `NSCursor.arrow.hotSpot` (eyeball check in Step 6).

---

### Task 1: The timeline

**Files:**
- Create: `WorkdeckTests/Screenshots/NotchAnimationTimeline.swift`
- Test: `WorkdeckTests/Screenshots/NotchAnimationTimelineTests.swift` (runs in `make test`; no rendering)

**Interfaces:**
- Produces:
  ```swift
  enum NotchAnimationPhase: Equatable { case compact(TimeInterval), pointerIn(TimeInterval), open(TimeInterval), expanded(TimeInterval), pointerOut(TimeInterval), close(TimeInterval), flash(TimeInterval) }
  struct NotchAnimationFrame: Equatable {
      var time: TimeInterval      // start, from the animation's start
      var delay: TimeInterval     // how long it shows
      var phase: NotchAnimationPhase
      var phaseTime: TimeInterval // start, from its phase's start
      var progress: Double        // 0 compact … 1 expanded; may pass 1 while opening
      var pointer: Double?        // 0 at the path's start … 1 resting on the notch; nil = not drawn
      var isLive: Bool            // the recorder waits `delay` of real time after it
  }
  enum NotchAnimationTimeline {
      static let transitionRate: Double = 30
      static let liveRate: Double = 10
      static let hover: [NotchAnimationPhase]   // Global Constraints
      static let alert: [NotchAnimationPhase]
      static func frames(_ phases: [NotchAnimationPhase], pointer: Bool) -> [NotchAnimationFrame]
      static func openingProgress(at time: TimeInterval, duration: TimeInterval) -> Double // Spring.bouncy(duration:).value(target: 1.0, time:)
      static func closingProgress(at time: TimeInterval, duration: TimeInterval) -> Double // 1 − Spring.smooth(duration:).value(target: 1.0, time:)
      static func eased(_ x: Double) -> Double // ease in-out, 0→0, 1→1
  }
  ```
- Pointer by phase (with `pointer: true`): nil in a compact hold before `pointerIn`; `eased` 0→1 over `pointerIn`; 1 during `open` and `expanded`; `eased` 1→0 over `pointerOut`; nil from `close` on. Live: `expanded`, `pointerOut`, `flash`. 30 fps: `pointerIn`, `open`, `close`. `pointerIn` is compact (progress 0); `pointerOut` is expanded (progress 1); `flash` is compact.

- [ ] **Step 1: Write the failing tests** in `NotchAnimationTimelineTests` (`@Suite struct`):
  - `theHoverAnimationLastsItsPhases`: `frames(hover, pointer: true).map(\.delay).reduce(0, +)` ≈ 6.8 (±1e-6); alert ≈ 6.3.
  - `aCompactHoldIsOneFrame`: `frames([.compact(1)], pointer: false)` == one frame, delay 1, progress 0, `isLive == false`.
  - `anExpandedHoldIsLiveTenTimesASecond`: `frames([.expanded(3.5)], pointer: false)` has 35 frames, each delay 0.1, progress 1, `isLive`.
  - `openingOvershootsAndSettles`: max of `openingProgress(at:duration: 0.4)` over 0…0.4 > 1; `openingProgress(at: 1.0, duration: 0.4)` ≈ 1 (±0.01); `openingProgress(at: 0, …) == 0`.
  - `closingEndsCompact`: `closingProgress(at: 0, …) == 1`; `closingProgress(at: 1.0, duration: 0.4)` ≈ 0 (±0.01).
  - `theLoopIsSeamless`: for hover and alert, first and last frames have progress 0 and pointer nil.
  - `thePointerComesInAndLeaves`: hover `pointerIn` frames' pointer values increase from < 0.1 to 1; `pointerOut` ends < 0.1; every alert frame's pointer is nil.

- [ ] **Step 2: Run, expect FAIL** (`-only-testing:WorkdeckTests/NotchAnimationTimelineTests`): "cannot find 'NotchAnimationTimeline' in scope".

- [ ] **Step 3: Implement** in `NotchAnimationTimeline.swift`, `nonisolated` value types. The last 30 fps frame of `open` is followed by `expanded` at progress 1 exactly; frames at rate r are at `phaseTime = k / r`, each `delay = 1 / r` (the last one trimmed to the phase's end).

- [ ] **Step 4: Run, expect PASS.**

---

### Task 2: The APNG writer

**Files:**
- Create: `WorkdeckTests/Screenshots/APNGWriter.swift`
- Test: `WorkdeckTests/Screenshots/APNGWriterTests.swift` (runs in `make test`; writes only to a temporary directory)

**Interfaces:**
- Produces: `enum APNGWriter { static func write(_ frames: [(image: CGImage, delay: TimeInterval)], to url: URL) throws }` — `CGImageDestinationCreateWithURL(url, UTType.png.identifier, frames.count, nil)`, file properties `[kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]`, each frame `[kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]`; throws `APNGWriter.Failure.noFrames` for an empty list and `.notWritten` when finalize fails.

- [ ] **Step 1: Write the failing tests:**
  - `delaysAreWrittenAsGiven`: three 4×4 solid images with delays 0.1, 0.5, 1.0 → `CGImageSourceGetCount == 3`; each frame's `kCGImagePropertyAPNGDelayTime` (or `…UnclampedDelayTime`) ≈ the given delay (±0.001).
  - `itLoopsForever`: the source's properties `kCGImagePropertyPNGDictionary[kCGImagePropertyAPNGLoopCount] == 0`.
  - `noFramesIsAnError`: `#expect(throws: APNGWriter.Failure.noFrames)`.

- [ ] **Step 2: Run, expect FAIL** ("cannot find 'APNGWriter'").
- [ ] **Step 3: Implement** as in Interfaces.
- [ ] **Step 4: Run, expect PASS.**

---

### Task 3: The transition view, the recorder and the two animations

**Files:**
- Create: `WorkdeckTests/Screenshots/NotchTransitionView.swift`
- Modify: `WorkdeckTests/Screenshots/ScreenshotRenderer.swift` (recorder), `WorkdeckTests/Screenshots/ScreenshotTests.swift` (two tests, `everyImageWasWritten`), `Makefile` (written-image count 10 → 12)

**Interfaces:**
- Consumes: `NotchAnimationTimeline.frames`, `NotchAnimationFrame` (Task 1); `APNGWriter.write` (Task 2); `ScreenshotFixtures.demoNotch(elapsed:)`, `NotchOutline`, `NotchGeometry`, `notchFrame` (existing).
- Produces:
  ```swift
  @Observable final class NotchAnimationState { var progress = 0.0; var pointer: Double? }
  struct NotchTransitionView: View {
      let model: LimitsNotchModel
      let state: NotchAnimationState
      let compactSize: CGSize    // the compact outline's size (measured from the compact still's layout)
      let expandedSize: CGSize   // the expanded outline's size (LimitsExpandedView in the notch insets)
      let canvas: CGSize
      let pointerStart: CGPoint  // where the pointer comes from, in canvas points
  }
  extension ScreenshotRenderer {
      /// One offscreen window for the whole animation; `update` sets the model and state for a frame.
      static func writeAnimation<V: View>(_ view: V, canvas: CGSize, frames: [NotchAnimationFrame], name: String,
                                          update: (NotchAnimationFrame) -> Void) throws -> URL
  }
  ```

- [ ] **Step 1: Write the rendering tests** in `ScreenshotTests` (enabled only with the switch, like the stills):
  - `notchHoverAnimation` and `notchAlertAnimation`: the file exists; `CGImageSourceGetCount > 1`; loop count 0; pixel width == `canvas.width * 2`; file size < 5_000_000 bytes.
  - `theCanvasFitsTheOvershoot`: the canvas height ≥ top margin + `expandedSize.height × max(opening progress)` and width ≥ `expandedSize.width × max(opening progress)` + side margins.
  - `everyImageWasWritten`: add `notch-hover-animated`, `notch-alert-animated`.

- [ ] **Step 2: Run `make screenshots`, expect FAIL** (missing symbols).

- [ ] **Step 3: Implement `NotchTransitionView`.** A `ZStack(alignment: .top)` on the canvas: the outline (`NotchOutline`, lerped size and radii, black fill) hanging from the top centre, clipping both contents per Global Constraints' transition rule (compact halves as `notchCompact` lays them out; expanded as `notchFrame`'s content without its margin); the pointer (`Image(nsImage: NSCursor.arrow.image)`) at the lerp between `pointerStart` and the compact notch's middle, offset by `NSCursor.arrow.hotSpot`, when `state.pointer` is non-nil.

- [ ] **Step 4: Implement `writeAnimation`.** Borderless `KeyWindow` as `write` (with `ActiveAppearance.install()` and `.tint`), host kept for all frames. Per frame: `update(frame)`, `layoutSubtreeIfNeeded`; settle 0.6 s before the first frame; before a non-live frame run the loop ~0.03 s; capture with `cacheDisplay` → `CGImage`; after a live frame run the loop for `frame.delay` of real time. Pass each frame's own `delay` to `APNGWriter` (never measured time). Check 2× width, `save`'s bookkeeping (`writtenThisRun`, "Wrote …").

- [ ] **Step 5: Drive the two animations** in the tests' `update` closures:
  - Hover: `model.state = demoNotch(elapsed: 12 + floor(time since the open phase started)).state` (cached per second; before opening, the second-12 state); `model.isHovering = pointer != nil`; `state.progress`, `state.pointer` from the frame.
  - Alert: state from second 30 throughout; `model.alerts = [the threshold alert]` and `model.countdown = NotchCountdown(start: now, duration: .seconds(2.9))` when `open` starts; alerts cleared when `flash` starts, with `model.flash = NotchFlashEvent(id: 1, ring: NotchFlash.color(of: alert, thresholds: [80, 95]), dot: nil, dotBlinks: false, startedAt: Date())`; `model.flash = nil` at the last compact phase.
  - Canvas: width `max(compactSize.width, expandedSize.width × maxOvershoot) + 2 × 24`, height `expandedSize.height × maxOvershoot + 24` (plus room for the pointer's start on hover).

- [ ] **Step 6: Run `make screenshots`, expect PASS**; open both files in a browser (or Quick Look) and check by eye: a seamless loop, the bounce, the spinner moving, the pointer's tip on the notch, the alert's ring flash. List their sizes (`ls -lh docs/media/screenshots/*-animated.png`); if one is over 4 MB, lower `transitionRate` to 20 first (spec §3.4).

---

### Task 4: Landing page, README, documentation

**Files:**
- Modify: `site/index.html` (slides 0 and 1), `README.md` ("Hover to see everything", "When something needs you" rows), `CLAUDE.md` (screenshots note), `TODO.md` (remove the GIF item), `scripts/release/test_install.py` (`PageTests`)

- [ ] **Step 1: Write the failing test** `test_animations_have_a_still_for_reduced_motion` in `PageTests`: `site/index.html` contains `screenshots/notch-hover-animated.png` and `screenshots/notch-alert-animated.png`, and for each a `<source media="(prefers-reduced-motion: reduce)" srcset="screenshots/notch-expanded.png">` / `…notch-alert.png">` before it.
- [ ] **Step 2: Run** `python3 -I scripts/release/test_install.py PageTests`, **expect FAIL**.
- [ ] **Step 3: Landing:** slides 0 and 1 become `<picture><source media="(prefers-reduced-motion: reduce)" srcset="screenshots/notch-….png"><img src="screenshots/notch-…-animated.png" …></picture>`, keeping the alt texts, `data-zoom` and `top` alignment; the first without `loading="lazy"`, the second with it.
- [ ] **Step 4: README:** the two rows' `src` become the animated files, widths as now (hover: from 220 px height of the animation's aspect ratio; alert: 360).
- [ ] **Step 5: CLAUDE.md** screenshots note: "`make screenshots` also writes `notch-hover-animated.png` and `notch-alert-animated.png` (APNG): `NotchAnimationTimeline` gives the frames, `writeAnimation` records them live in one window, `APNGWriter` writes them." **TODO:** remove "GIFs of the notch on the landing page".
- [ ] **Step 6: Run** `python3 -I scripts/release/test_install.py` and `make test`, **expect PASS**; refresh the companion preview of the landing page for the user.
