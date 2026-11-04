# Automatic Screenshots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `make screenshots` renders Workdeck's parts from made-up data into `docs/media/screenshots/`, and the README and landing page show them.

**Architecture:** A test-only `ScreenshotTests` suite (skipped unless `WORKDECK_SCREENSHOTS=1`) builds each part with the existing test fakes and demo scripts, renders it through an offscreen `NSWindow`/`NSHostingView` helper (the approved spike's method) at 2× in light and dark, and writes PNGs. No product code changes.

**Tech Stack:** Swift Testing, AppKit/SwiftUI offscreen rendering, Make, static HTML.

**Spec:** `specs/2026-11-04-screenshots-design.md`

## Global Constraints

- Output folder `docs/media/screenshots/`; files exactly as spec §2's table.
- 2× pixels: an image's pixel width is twice its point width.
- Fixed clock (demo dates), calendar `RecapCalendar.calendar(timeZone: Europe/Berlin)`, locale `en_US_POSIX` where formatting depends on it; Reduce Motion or no animations so a frame never catches a transition.
- Never the real `~/.claude*`, `~/.codex`, Keychain, network or `UserDefaults.standard`: temp dirs, `UserDefaults(suiteName:)`, existing fakes.
- Notch exactly as the real view (300 pt `LimitsExpandedView`, truncation kept); windows without title bar or toolbar.
- Without `WORKDECK_SCREENSHOTS=1` the suite writes nothing.
- No commits until the user says "коммить".
- Commands: `make screenshots`; the suite alone `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ScreenshotTests TEST_RUNNER_WORKDECK_SCREENSHOTS=1 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`.

## Review Focus

- `make test` must not render or touch `docs/media/screenshots/`. Pinned by `withoutTheSwitchNothingIsWritten` (Task 1).
- No real data in an image: every controller built from temp dirs and fakes. Pinned by construction in each task and by the reviewer reading the fixtures; plus `theFixturesUseTemporaryFolders` asserting every URL handed to stores is under the test's temp dir (Task 2).
- A view caught mid-animation or before `onAppear` ran (empty list, missing selection). Pinned by the settle step in the helper and by eyeballing the output in Task 4.
- Image sizes: an image over ~600 KB. Checked in Task 4's step that lists sizes.
- Light/dark pairs exist for every window part. Pinned by `everyImageWasWritten` (Task 3).

---

### Task 1: The rendering helper and the switch

**Files:**
- Create: `WorkdeckTests/Screenshots/ScreenshotRenderer.swift`, `WorkdeckTests/Screenshots/ScreenshotTests.swift`
- Modify: `Makefile` (`screenshots` target), `.gitignore` (nothing to add unless the helper writes temp files outside the temp dir)
- Delete: `WorkdeckTests/ZZScreenshotSpikeTests.swift` (the spike)

**Interfaces:**
- Produces:

```swift
@MainActor enum ScreenshotRenderer {
    static var isEnabled: Bool            // ProcessInfo env WORKDECK_SCREENSHOTS == "1"
    static var outputFolder: URL          // <repo>/docs/media/screenshots, from #filePath
    /// Renders `view` offscreen at `width` points (or its fitting size), in light or dark, 2×, and writes `<name>.png`.
    @discardableResult
    static func write<V: View>(_ view: V, name: String, dark: Bool, width: CGFloat?) throws -> URL
}
@MainActor func notchFrame<V: View>(_ content: V) -> some View   // black notch shape around the content, as the spike
```

- [ ] **Step 1: Write the switch test**

```swift
@Test func withoutTheSwitchNothingIsWritten() throws {
    // Runs in every `make test`: the suite's rendering tests are disabled, and the folder is untouched.
    try #require(!ScreenshotRenderer.isEnabled)   // skipped when the switch is on (use .enabled(if:))
    let before = try? FileManager.default.contentsOfDirectory(atPath: ScreenshotRenderer.outputFolder.path)
    // (no rendering test ran in this process: they are .enabled(if: ScreenshotRenderer.isEnabled))
    #expect((try? FileManager.default.contentsOfDirectory(atPath: ScreenshotRenderer.outputFolder.path)) == before)
}
```

Rendering tests carry `.enabled(if: ScreenshotRenderer.isEnabled)` and the suite is `.serialized`.

- [ ] **Step 2: Run the suite; expect a compile failure (no helper)**

- [ ] **Step 3: Implement `ScreenshotRenderer`** from the spike (`ZZScreenshotSpikeTests.snapshot`): borderless offscreen window, `NSHostingView` with appearance, width → fitting height, settle the run loop ~0.6 s, `bitmapImageRepForCachingDisplay`/`cacheDisplay`, assert the rep's pixel width == 2 × points (fail clearly on a 1× display context), create the folder, write PNG. `notchFrame` = the spike's padding and `UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26)` on black with a 24 pt clear margin. Makefile:

```make
## screenshots: render the README and landing page images from demo data into docs/media/screenshots
screenshots:
	set -o pipefail; xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' test \
		-only-testing:WorkdeckTests/ScreenshotTests TEST_RUNNER_WORKDECK_SCREENSHOTS=1 2>&1 \
		| grep -E "error:|recorded an issue|Test run with|\*\* TEST|docs/media/screenshots"
```

(add `screenshots` to `.PHONY`). Delete the spike file.

- [ ] **Step 4: Run `make test`; expect green and no `docs/media/screenshots/` created**

---

### Task 2: Notch images and the Statistics window

**Files:**
- Modify: `WorkdeckTests/Screenshots/ScreenshotTests.swift`
- Create: `WorkdeckTests/Screenshots/ScreenshotFixtures.swift` (builders shared by the tests)

**Interfaces:**
- Consumes: `ScreenshotRenderer`, `notchFrame` (Task 1); `ClaudeCodeController` demo driving as in `ClaudeCodeDemoControllerTests.makeController`; `FakePresenter`, `FakeConnector`, `FakePoller`, `FakeActivity`, `FakeLiveness`, `FakeHooksConnector`, `FakeActivator`, `FakeSleepPreventer` (existing); `LimitsNotchModel`, `LimitsExpandedView`, `LimitsCompactLeading`, `LimitsCompactTrailing`, `SessionsCounter` (app); `RecapDemoScript`, `StatisticsController`, `StatisticsContent`.
- Produces: `ScreenshotFixtures.demoNotchState(elapsed: TimeInterval) throws -> LimitsViewState`, `ScreenshotFixtures.statistics() -> StatisticsController`, `ScreenshotFixtures.temporaryRoot: URL`.

- [ ] **Step 1: Write the tests** (each `.enabled(if: ScreenshotRenderer.isEnabled)`)

```swift
@Test func notchCompact() throws        // compact leading + trailing around a black gap the width of a notch, state at demo second 12 → notch-compact.png
@Test func notchExpanded() throws       // LimitsExpandedView with state at second 12 → notch-expanded.png
@Test func notchAlert() throws          // model.alerts = [the demo's threshold alert, 5-hour at 80%] → notch-alert.png
@Test func notchRecap() throws          // model.recap = RecapDemoScript.recap(now:calendar:) → notch-recap.png
@Test func statistics() throws          // StatisticsContent, demo days, a fixed Thursday, 460 pt, light and dark → statistics-light/dark.png
@Test func theFixturesUseTemporaryFolders() // every URL the fixtures create is under temporaryRoot
```

Each asserts the written file exists and its pixel width is 2× the width used.

- [ ] **Step 2: Run the suite with the switch; expect failures (no fixtures)**

- [ ] **Step 3: Implement `ScreenshotFixtures`** following `ClaudeCodeDemoControllerTests.makeController` (temp directory, `cameraHousings: { [true] }`, settings enabled, `demoDidStart`, `demoTick(elapsed: 12, previous: 11)`, `presenter.shown.last`). The compact image draws the real compact views the presenter uses (read `NotchPresenter` for which views and spacing make the compact notch) on black; the gap between them stands for the camera housing (~180 pt).

- [ ] **Step 4: Run the suite with the switch; expect green and six files; look at each image**

---

### Task 3: Popover and Chats

**Files:**
- Modify: `WorkdeckTests/Screenshots/ScreenshotTests.swift`, `WorkdeckTests/Screenshots/ScreenshotFixtures.swift`

**Interfaces:**
- Consumes: Task 2's fixtures; `PopoverView(controller:claudeCode:codex:recap:demo:updates:)`; `LidSleepController` with `FakeHelperClient`/`FakeHelperInstaller`/`FakePowerSourceMonitor`/`FakeThermalMonitor` and `AppSettings(defaults:)` (as `LidSleepControllerTests`); `CodexController(settings:limits:sessions:composer:clock:)` as `CodexControllerTests`; `UpdateController` with `InertUpdater`; `ChatsController(instances:index:launcher:liveSessions:vscode:vscodeWorkspaces:defaults:now:)` and `ChatsWindow` as `ChatsControllerTests` build them; `UsageSnapshotFile.write` for the Claude snapshot; session event files as `ClaudeSessionStore` tests write them.

- [ ] **Step 1: Write the tests**

```swift
@Test func popover() throws     // 300 pt, light and dark → popover-light/dark.png; Closed-Lid Mode on (helper fake sleepDisabled = true, controller enabled), Claude Code row with a seeded snapshot (5h 55 %, 7d 61 %) and sessions, Codex row with seeded limits and a session
@Test func chats() throws       // ChatsWindow at its default width (640 pt), light and dark → chats-light/dark.png; made-up transcripts under temporaryRoot for instances main and personal: projects orbit-app, api-server, docs-site; titles "Fix the orbit renderer", "Add rate limiting", "Write the API guide"
@Test func everyImageWasWritten() // after the others (the suite is serialized): all 11 files from spec §2 exist
```

- [ ] **Step 2: Run with the switch; expect failures**

- [ ] **Step 3: Implement the fixtures.** Seed only temp folders; the rows show whatever the app derives from that data (no product change). If a row still shows "Not connected" or similar because a connector fake reports it, set the fake to connected — never change product code for the image.

- [ ] **Step 4: Run with the switch; expect green; look at both images in both modes**

---

### Task 4: Images in the README and on the page

**Files:**
- Modify: `README.md`, `site/index.html`, `.github/workflows/pages.yml`, `CLAUDE.md`, `TODO.md`
- Add: `docs/media/screenshots/*.png` (generated by `make screenshots`)

- [ ] **Step 1: `make screenshots`; list sizes (`ls -l docs/media/screenshots`); flag anything over ~600 KB**
- [ ] **Step 2: README** — the expanded notch under the badges; under Features a row of images (compact notch, alert, recap, popover, Statistics, Chats) with `<picture>` light/dark pairs; alt text on each.
- [ ] **Step 3: Page** — the expanded notch under the install box; a row of the others above "What does Workdeck do?", `<picture>` light/dark, `loading="lazy"` below the fold, width/height attributes; `pages.yml` copies `docs/media/screenshots/` to `_site/screenshots/` and adds `docs/media/screenshots/**` to its paths filter.
- [ ] **Step 4: CLAUDE.md** — Build and Test: `make screenshots`; Conventions: a change to how the notch, popover, Statistics or Chats look ends with `make screenshots` and the new images in the same commit; Architecture: `WorkdeckTests/Screenshots/`. TODO: README media — screenshots done (spec), video still open.
- [ ] **Step 5: Show the user the README and page with images (the companion tab or a local preview); placement changes go here before "коммить".**
- [ ] **Step 6: `make test`; expect green and `git status` shows no change under `docs/media/screenshots/` from the test run itself.**
