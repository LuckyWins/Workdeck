# Notch Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An expanded alert or recap gets a color wash from below and a countdown bar to its close; the focused session's step ticker animates; Settings section headers get icon tiles.

**Architecture:** A pure `NotchCountdown` (start, end, fraction) is set on `LimitsNotchModel` by `NotchPresenter`, whose alert loop moves to a deadline so a joining alert restarts the time exactly; the model also mirrors the presenter's hover state. Views: `NotchWash` and `CountdownBar` in `LimitsExpandedView`; the ticker's marks, shimmer, transitions and edge mask in `SessionsList`; `SettingsHeader` tiles in the four Settings sections.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing.

**Spec:** `specs/2026-10-13-notch-polish-design.md`

## Global Constraints

- Wash colors are the flash colors (`NotchFlash.color(of:thresholds:)`); a batch takes its most urgent; the recap's wash is indigo; none in the normal expanded view.
- Countdown: 2 pt, white 35 %, 160 pt at full, shown the whole time an alert (6 s) or the recap (60 s) is expanded, shrinking to zero at the close; hidden while hovered; none with Reduce Motion.
- Ticker: finished steps show `✓` in `Terminal.faint`, the current `▸`; demotion 0.38 s `timingCurve(0.4, 0, 0.2, 1)`, scale 0.92, 4 pt left; shimmer period 2.2 s; edge fade top 16 %, bottom 8 %; Reduce Motion keeps only the mark change.
- Settings tiles 20 × 20, corner radius 5, white SF Symbol: General `gearshape.fill` gray, Closed-Lid Mode `laptopcomputer` indigo, Limits `gauge.with.dots.needle.50percent` orange, Sessions `terminal.fill` green, Instances `person.2.fill` blue, About `info.circle.fill` gray.
- Alert texts, durations, clicks and flashes are unchanged; DynamicNotchKit is not modified.
- Commits: none per task; the user commits after checking ("коммить"). Conventional Commits, no `Co-Authored-By`, no mention of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.
- Look checks: render a view to PNG with a temporary test (`ImageRenderer`, see Task 3 Step 4) that is deleted before the task ends; never commit it.

## Review Focus

1. An alert joining a shown one must keep the notch up a full `alertDuration` from the join, and the countdown must restart then — pinned in Task 1 (`aJoiningAlertRestartsTheCountdown`).
2. The countdown must be gone once an alert or the recap closes, and when "needs you" interrupts the recap — pinned in Task 1 (`theCountdownEndsWithTheAlert`, `theRecapCountsDownItsMinute`, `needsYouEndsTheRecapsCountdown`).
3. The model's hover flag must follow the delayed hover, not the raw signal — pinned in Task 1 (`theModelFollowsTheDelayedHover`).
4. A ticker waiting for an agent (no current step) must show only `✓` marks — pinned in Task 2 (`stepMarks`).
5. The wash must not cover text contrast in the batch layout or the recap; checked with snapshots in Task 3.

---

### Task 1: Countdown in the model and a deadline-based alert loop

**Files:**
- Create: `Workdeck/Features/ClaudeCode/NotchCountdown.swift`
- Modify: `Workdeck/Features/ClaudeCode/NotchPresenter.swift`, `Workdeck/Features/ClaudeCode/LimitsNotchViews.swift` (`LimitsNotchModel`)
- Test: create `WorkdeckTests/ClaudeCode/NotchCountdownTests.swift`; `WorkdeckTests/ClaudeCode/NotchPresenterTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated struct NotchCountdown: Equatable, Sendable { let start: Date; let end: Date; init(start: Date, duration: Duration); func fraction(at date: Date) -> Double }`
  - `LimitsNotchModel.countdown: NotchCountdown?`, `LimitsNotchModel.isHovering: Bool`

- [ ] **Step 1: Write the failing tests**

Create `WorkdeckTests/ClaudeCode/NotchCountdownTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct NotchCountdownTests {
    @Test func fractionRunsFromOneToZero() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let countdown = NotchCountdown(start: start, duration: .milliseconds(6000))
        #expect(countdown.end == start.addingTimeInterval(6))
        #expect(countdown.fraction(at: start.addingTimeInterval(-1)) == 1)
        #expect(countdown.fraction(at: start) == 1)
        #expect(abs(countdown.fraction(at: start.addingTimeInterval(1.5)) - 0.75) < 0.0001)
        #expect(countdown.fraction(at: start.addingTimeInterval(6)) == 0)
        #expect(countdown.fraction(at: start.addingTimeInterval(9)) == 0)
    }
}
```

Append to `NotchPresenterTests` (inside the struct, next to the recap tests):

```swift
    private func waitFor(_ condition: () -> Bool) async {
        while !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func theCountdownEndsWithTheAlert() async throws {
        let (presenter, _) = makePresenter(alertDuration: .milliseconds(300))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionFinished(project: "a", worked: 60)])
        await waitFor { !presenter.model.alerts.isEmpty }
        let countdown = try #require(presenter.model.countdown)
        #expect(abs(countdown.end.timeIntervalSince(countdown.start) - 0.3) < 0.001)
        await waitFor { presenter.model.alerts.isEmpty }
        #expect(presenter.model.countdown == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aJoiningAlertRestartsTheCountdown() async throws {
        let (presenter, _) = makePresenter(alertDuration: .milliseconds(400))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionFinished(project: "a", worked: 60)])
        await waitFor { !presenter.model.alerts.isEmpty }
        let first = try #require(presenter.model.countdown)
        try? await Task.sleep(for: .milliseconds(200))
        presenter.flash([.sessionFinished(project: "b", worked: 60)])
        await waitFor { presenter.model.alerts.count == 2 }
        let joined = Date()
        let second = try #require(presenter.model.countdown)
        #expect(second.start.timeIntervalSince(first.start) > 0.15)
        await waitFor { presenter.model.alerts.isEmpty }
        // Up a full alert time from the join, not the first alert's time plus another one.
        let shown = Date().timeIntervalSince(joined)
        #expect(shown >= 0.35)
        #expect(shown < 0.75)
    }

    @Test(.timeLimit(.minutes(1)))
    func theRecapCountsDownItsMinute() async throws {
        let (presenter, _) = makePresenter(recapDuration: .milliseconds(300))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        await waitFor { presenter.model.countdown != nil }
        let countdown = try #require(presenter.model.countdown)
        #expect(abs(countdown.end.timeIntervalSince(countdown.start) - 0.3) < 0.001)
        await waitFor { !presenter.isBusy }
        #expect(presenter.model.countdown == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func needsYouEndsTheRecapsCountdown() async {
        let (presenter, _) = makePresenter(alertDuration: .milliseconds(200), recapDuration: .seconds(30))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.showRecap(recap())
        await waitFor { presenter.model.countdown != nil }
        presenter.flash([.sessionNeedsYou(project: "a")])
        await waitFor { !presenter.model.alerts.isEmpty }
        // The alert's own countdown replaced the recap's minute.
        let countdown = presenter.model.countdown
        #expect(countdown.map { $0.end.timeIntervalSince($0.start) < 1 } == true)
        await waitFor { presenter.model.alerts.isEmpty }
        #expect(presenter.model.countdown == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func theModelFollowsTheDelayedHover() async {
        let (presenter, _) = makePresenter(hoverEnterDelay: .milliseconds(100), hoverExitDelay: .milliseconds(100))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!presenter.model.isHovering)
        await waitFor { presenter.model.isHovering }
        surface.onHoverChange?(false)
        await waitFor { !presenter.model.isHovering }
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchCountdownTests -only-testing:WorkdeckTests/NotchPresenterTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `cannot find 'NotchCountdown' in scope`, `value of type 'LimitsNotchModel' has no member 'countdown'` / `'isHovering'`.

- [ ] **Step 3: Implement**

Create `Workdeck/Features/ClaudeCode/NotchCountdown.swift`:

```swift
import Foundation

/// How long an expanded alert or recap has left before the notch closes it (notch polish spec §3).
nonisolated struct NotchCountdown: Equatable, Sendable {
    let start: Date
    let end: Date

    init(start: Date, duration: Duration) {
        self.start = start
        let parts = duration.components
        end = start.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    /// 1 at the start, 0 at the end and after, linear between.
    func fraction(at date: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, end.timeIntervalSince(date) / total))
    }
}
```

`LimitsNotchViews.swift`, in `LimitsNotchModel` after `var recap: WeeklyRecapSummary?`:

```swift
    /// The time left of the expanded alert or recap, for the countdown bar (notch polish spec §3).
    var countdown: NotchCountdown?
    /// The pointer is on the notch, after the hover delays; the countdown bar hides meanwhile.
    var isHovering = false
```

`NotchPresenter.swift`:

- Replace `private var isHovering = false` with

```swift
    private var isHovering = false {
        didSet {
            if model.isHovering != isHovering {
                model.isHovering = isHovering
            }
        }
    }
```

- Replace `private var isAlertExtended = false` with

```swift
    /// When the shown alerts close; an alert that joins them moves it to a full `alertDuration` from then.
    private var alertDeadline: ContinuousClock.Instant?
```

- In `present(_:)`, replace

```swift
        if isShowingAlert {
            model.alerts.append(contentsOf: alerts)
            isAlertExtended = true
            return
        }
```

with

```swift
        if isShowingAlert {
            model.alerts.append(contentsOf: alerts)
            restartAlertTime()
            return
        }
```

and replace

```swift
                isShowingAlert = true
                requestReconcile()
                repeat {
                    isAlertExtended = false
                    try? await Task.sleep(for: alertDuration)
                } while isAlertExtended && screen() != nil
            }
            pendingAlerts.removeAll()
            model.alerts = []
```

with

```swift
                isShowingAlert = true
                restartAlertTime()
                requestReconcile()
                while let deadline = alertDeadline, ContinuousClock.now < deadline, screen() != nil, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            pendingAlerts.removeAll()
            alertDeadline = nil
            model.countdown = nil
            model.alerts = []
```

- After `present(_:)` add:

```swift
    /// Shows the alerts a full `alertDuration` from now, with the countdown from full.
    private func restartAlertTime() {
        alertDeadline = .now + alertDuration
        model.countdown = NotchCountdown(start: Date(), duration: alertDuration)
    }
```

- In `showRecap(_:)`, replace

```swift
            repeat {
                try? await Task.sleep(for: recapDuration)
            } while isHovering && !Task.isCancelled
            guard !Task.isCancelled else { return }
            isShowingRecap = false
            recapTask = nil
```

with

```swift
            repeat {
                model.countdown = NotchCountdown(start: Date(), duration: recapDuration)
                try? await Task.sleep(for: recapDuration)
            } while isHovering && !Task.isCancelled
            guard !Task.isCancelled else { return }
            model.countdown = nil
            isShowingRecap = false
            recapTask = nil
```

- In `endRecapExpansion()`, inside `if isShowingRecap {`, add `model.countdown = nil` as its first line.

- [ ] **Step 4: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchCountdownTests -only-testing:WorkdeckTests/NotchPresenterTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues (the existing joining and recap tests still pass).

---

### Task 2: Ticker marks, shimmer and motion

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/Sessions/SessionsText.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionsNotchViews.swift`, `Workdeck/Features/ClaudeCode/TerminalStyle.swift`
- Test: `WorkdeckTests/ClaudeCode/TerminalStyleTests.swift` (it already covers `SessionsText`), create `WorkdeckTests/ClaudeCode/TickerShimmerTests.swift`

**Interfaces:**
- Produces: `static SessionsText.stepMark(_ step: StepRow) -> String`; `nonisolated enum TickerShimmer { static let period: TimeInterval = 2.2; static func phase(at date: Date) -> Double }` (−0.3 … 1.3, the band's center across the text).

- [ ] **Step 1: Write the failing tests**

Append to `TerminalStyleTests`:

```swift
    @Test func stepMarks() {
        #expect(SessionsText.stepMark(StepRow(id: "a", action: "Read A", lines: nil, age: 0, opacity: 1)) == "▸")
        #expect(SessionsText.stepMark(StepRow(id: "b", action: "Read B", lines: nil, age: 1, opacity: 0.25)) == "✓")
        // Waiting for an agent: no current step, every shown step is done.
        #expect(SessionsText.stepMark(StepRow(id: "c", action: "Read C", lines: nil, age: 3, opacity: 0.25)) == "✓")
    }
```

Create `WorkdeckTests/ClaudeCode/TickerShimmerTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

struct TickerShimmerTests {
    @Test func theBandSweepsAcrossOncePerPeriod() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(abs(TickerShimmer.phase(at: start) - -0.3) < 0.0001)
        #expect(abs(TickerShimmer.phase(at: start.addingTimeInterval(1.1)) - 0.5) < 0.0001)
        #expect(abs(TickerShimmer.phase(at: start.addingTimeInterval(2.2)) - -0.3) < 0.0001)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/TerminalStyleTests -only-testing:WorkdeckTests/TickerShimmerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `type 'SessionsText' has no member 'stepMark'`, `cannot find 'TickerShimmer' in scope`.

- [ ] **Step 3: Implement the helpers**

In `SessionsText` (any place among the static functions):

```swift
    /// The current step's `▸`; a finished one's `✓` (notch polish spec §4).
    static func stepMark(_ step: StepRow) -> String {
        step.age == 0 ? "▸" : "✓"
    }
```

At the end of `TerminalStyle.swift`:

```swift
/// The current step's shimmer: a light band crossing the text every `period` (notch polish spec §4).
nonisolated enum TickerShimmer {
    static let period: TimeInterval = 2.2

    /// The band's center across the text, from −0.3 (before it) to 1.3 (past it).
    static func phase(at date: Date) -> Double {
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return -0.3 + 1.6 * progress
    }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/TerminalStyleTests -only-testing:WorkdeckTests/TickerShimmerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

- [ ] **Step 5: The ticker view**

In `SessionsList`:

- Add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` after `@State private var hoveredID: String?`.
- In `rowView(_:at:)`, replace

```swift
            ForEach(row.steps) { step in
                stepView(step)
                    // A new step slides in at the bottom; the oldest fades out where it is, at the top (spec §3.5).
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
            }
```

with

```swift
            if !row.steps.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(row.steps) { step in
                        stepView(step, at: date)
                            // A new step slides in from below; the oldest rises and fades out (notch polish spec §4).
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity.combined(with: .move(edge: .top))
                            ))
                    }
                }
                .padding(.vertical, 2)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.16),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .animation(reduceMotion ? nil : .timingCurve(0.4, 0, 0.2, 1, duration: 0.38), value: row.steps.map(\.id))
            }
```

- Replace `stepView(_:)` with:

```swift
    /// One ticker line, lined up with the project name: the current step bright with `▸` and a shimmer, finished
    /// ones faint with `✓`, a little smaller and to the left (notch polish spec §4).
    private func stepView(_ step: StepRow, at date: Date) -> some View {
        let isCurrent = step.age == 0
        return HStack(spacing: 6) {
            // Takes the status dot's width.
            Text("●").hidden()
            HStack(spacing: 6) {
                Text(SessionsText.stepMark(step))
                    .foregroundStyle(isCurrent ? Terminal.text : Terminal.faint)
                stepText(step, isCurrent: isCurrent, at: date)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let lines = step.lines {
                    LineCountsText(lines: lines)
                        .opacity(isCurrent ? 1 : 0.4)
                }
            }
            .font(Terminal.font(10))
            .scaleEffect(isCurrent || reduceMotion ? 1 : 0.92, anchor: .leading)
            .offset(x: isCurrent || reduceMotion ? 0 : -4)
        }
    }

    @ViewBuilder
    private func stepText(_ step: StepRow, isCurrent: Bool, at date: Date) -> some View {
        if isCurrent && !reduceMotion {
            let phase = TickerShimmer.phase(at: date)
            Text(step.action)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Terminal.dim, location: 0),
                            .init(color: Terminal.text, location: 0.5),
                            .init(color: Terminal.dim, location: 1),
                        ],
                        startPoint: UnitPoint(x: phase - 0.3, y: 0.5),
                        endPoint: UnitPoint(x: phase + 0.3, y: 0.5)
                    )
                )
        } else {
            Text(step.action)
                .foregroundStyle(isCurrent ? Terminal.text : Terminal.faint)
        }
    }
```

- In `body`, remove the line `.animation(.snappy, value: state.rows.map { $0.steps.map(\.id) })` (the ticker now animates itself with the spec's curve).

The `TimelineView` around the list already ticks every `TerminalSpinner.frameInterval` (0.1 s) while the notch is expanded, which drives the shimmer; nothing new runs while it is collapsed.

- [ ] **Step 6: Build and run the whole suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.

---

### Task 3: Wash and countdown bar in the expanded notch

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/TerminalStyle.swift`, `Workdeck/Features/ClaudeCode/LimitsNotchViews.swift`

**Interfaces:**
- Consumes: `LimitsNotchModel.countdown`, `LimitsNotchModel.isHovering` (Task 1); `NotchFlash.color(of:thresholds:)` (both overloads), `NotchFlashColor.color`.
- Produces: `struct NotchWash: View { let color: Color }`, `struct CountdownBar: View { let countdown: NotchCountdown }`.

SwiftUI views have no unit tests in this project; the gate is a clean build, the green suite and snapshots.

- [ ] **Step 1: The two views**

At the end of `TerminalStyle.swift`:

```swift
/// A soft glow rising from below the expanded notch's bottom edge in an alert's color (notch polish spec §2).
/// Drawn past the content's insets; the notch's own mask clips it to the panel.
struct NotchWash: View {
    static let reach: CGFloat = 40

    let color: Color

    var body: some View {
        EllipticalGradient(
            colors: [color.opacity(0.5), color.opacity(0)],
            center: UnitPoint(x: 0.5, y: 1.35),
            startRadiusFraction: 0,
            endRadiusFraction: 0.7
        )
        .padding(-Self.reach)
        .allowsHitTesting(false)
    }
}

/// A thin bar that shrinks to nothing when the notch closes the alert or recap (notch polish spec §3).
struct CountdownBar: View {
    static let width: CGFloat = 160

    let countdown: NotchCountdown

    @State private var fraction: Double = 1

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.35))
            .frame(width: Self.width * fraction, height: 2)
            .frame(width: Self.width)
            .task(id: countdown) {
                let now = Date()
                fraction = countdown.fraction(at: now)
                withAnimation(.linear(duration: max(0, countdown.end.timeIntervalSince(now)))) {
                    fraction = 0
                }
            }
            .allowsHitTesting(false)
    }
}
```

- [ ] **Step 2: Use them in `LimitsExpandedView`**

- Add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` after `@State private var hoveredAlert: String?`.
- In `body`, after `.padding(.vertical, 10)` (the last modifier of the `Group`), add:

```swift
        .background {
            if let wash = washColor {
                NotchWash(color: wash)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: washColor)
        .overlay(alignment: .bottom) {
            // In DynamicNotchKit's bottom inset, under the content.
            if let countdown = model.countdown, !model.isHovering, !reduceMotion {
                CountdownBar(countdown: countdown)
                    .offset(y: 16)
                    .transition(.opacity)
            }
        }
```

- Add the color source after `body`:

```swift
    /// The wash under an expanded alert, a batch or the recap; none in the usual view (notch polish spec §2).
    private var washColor: Color? {
        if !model.alerts.isEmpty {
            return NotchFlash.color(of: model.alerts, thresholds: model.state.thresholds)?.color
        }
        return model.recap != nil ? .indigo : nil
    }
```

Note: `model.recap` is also set while the recap waits as `◆`; then the expanded view shows it only on hover, and the indigo wash with it is intended.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' build 2>&1 | grep -E "error:|\*\* BUILD"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Snapshots**

Create `WorkdeckTests/ZZRenderNotchTests.swift` (temporary, deleted in Step 5):

```swift
import AppKit
import SwiftUI
import Testing
@testable import Workdeck

// Temporary: renders the expanded notch for a visual check; not committed.
@MainActor
struct ZZRenderNotchTests {
    private func render(_ model: LimitsNotchModel, _ name: String) throws {
        let view = LimitsExpandedView(model: model)
            .padding(.horizontal, 15)
            .padding(.bottom, 15)
            .padding(.top, 32)
            .frame(width: 420)
            .background(.black)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let rep = try #require(NSBitmapImageRep(data: try #require(image.tiffRepresentation)))
        let directory = ProcessInfo.processInfo.environment["RENDER_DIR"] ?? NSTemporaryDirectory()
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(filePath: directory).appending(path: "\(name).png"))
    }

    @Test func renderAlerts() throws {
        let model = LimitsNotchModel()
        model.state = LimitsViewState(display: .notch(.normal), windows: [], now: Date(), age: nil, thresholds: [80, 95])
        model.alerts = [.sessionNeedsYou(project: "vitastir")]
        model.countdown = NotchCountdown(start: Date().addingTimeInterval(-2), duration: .seconds(6))
        try render(model, "needs-you")
        model.alerts = [.sessionFinished(project: "Workdeck", worked: 720), .sessionNeedsYou(project: "vitastir")]
        try render(model, "batch")
        model.alerts = []
        model.recap = WeeklyRecapSummary(weekStart: Date(), seconds: 3600, sessions: 2)
        try render(model, "recap")
    }
}
```

Run: `TEST_RUNNER_RENDER_DIR=<scratchpad> xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ZZRenderNotchTests 2>&1 | grep -E "error:|\*\* TEST"` and read the three PNGs.
Expected: an orange wash rising from the bottom under "vitastir needs you", orange for the batch (needs you beats finished), indigo under the recap; text readable; the bar is not in the snapshot (`ImageRenderer` does not run `.task`) — the bar is checked live. If the wash is too strong or too weak, tune `0.5` in `NotchWash` and record a ruling.

- [ ] **Step 5: Remove the snapshot test and run the suite**

Delete `WorkdeckTests/ZZRenderNotchTests.swift`.

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues; `git status --short WorkdeckTests` lists no `ZZRender` file.

---

### Task 4: Settings tiles

**Files:**
- Create: `Workdeck/App/SettingsHeader.swift`
- Modify: `Workdeck/App/SettingsView.swift`, `Workdeck/Features/ClaudeCode/Limits/ClaudeLimitsSettingsSection.swift`, `Workdeck/Features/ClaudeCode/Sessions/ClaudeSessionsSettingsSection.swift`, `Workdeck/Features/ClaudeCode/Instances/InstancesSettingsSection.swift`

**Interfaces:**
- Produces: `struct SettingsHeader: View { init(_ title: String, symbol: String, color: Color) }`

- [ ] **Step 1: The header view**

Create `Workdeck/App/SettingsHeader.swift`:

```swift
import SwiftUI

/// A Settings section title with a colored icon tile, as in System Settings (notch polish spec §5).
struct SettingsHeader: View {
    let title: String
    let symbol: String
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(color.gradient))
        }
    }
}
```

- [ ] **Step 2: Use it**

- `SettingsView.swift`: replace `Section("General") {` … its closing `}` by `Section { … } header: { SettingsHeader("General", symbol: "gearshape.fill", color: .gray) }` (same content); replace `Text("Closed-Lid Mode")` in its header with `SettingsHeader("Closed-Lid Mode", symbol: "laptopcomputer", color: .indigo)`; replace `Text("About")` with `SettingsHeader("About", symbol: "info.circle.fill", color: .gray)`.
- `ClaudeLimitsSettingsSection.swift`: `Text("Claude Code · Limits")` → `SettingsHeader("Claude Code · Limits", symbol: "gauge.with.dots.needle.50percent", color: .orange)`.
- `ClaudeSessionsSettingsSection.swift`: `Text("Claude Code · Sessions")` → `SettingsHeader("Claude Code · Sessions", symbol: "terminal.fill", color: .green)`.
- `InstancesSettingsSection.swift`: `Text("Claude Code · Instances")` → `SettingsHeader("Claude Code · Instances", symbol: "person.2.fill", color: .blue)`.

- [ ] **Step 3: Build, snapshot, suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' build 2>&1 | grep -E "error:|\*\* BUILD"` → `** BUILD SUCCEEDED **`.

Snapshot one header with a temporary test (as in Task 3 Step 4, rendering `VStack { SettingsHeader("Claude Code · Limits", symbol: "gauge.with.dots.needle.50percent", color: .orange); SettingsHeader("Closed-Lid Mode", symbol: "laptopcomputer", color: .indigo) }.padding().background(Color(white: 0.12))`), read it, delete the test.

Run the whole suite: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"` → `** TEST SUCCEEDED **`.

---

### Task 5: Documentation

**Files:**
- Modify: `docs/testing.md`, `specs/2026-10-13-alert-badge-design.md`, `specs/2026-10-13-edit-counts-and-step-ticker-design.md`, `specs/2026-10-13-notch-polish-design.md`, `README.md`

- [ ] **Step 1: docs/testing.md**

- In rows L5, L9, S11, S12 (alerts), after the glowing badge text add: "; a wash in the same color rises from the bottom edge, and a thin bar at the bottom shrinks to nothing as the alert closes (it hides while the pointer is on the notch)".
- In row R1 (recap), after "The notch expands with" … add: "an indigo wash from below and a bar that shrinks over the minute".
- Add a row at the end of the Claude Code Sessions Checklist: `| S30 | Ticker motion | Let a session run several tools in a row with the notch expanded. | A finished step moves up and shrinks a little, its ▸ turns into ✓; the new step slides in from below; the current step's text shimmers; the list fades at its top and bottom edges. With Reduce Motion only ▸ → ✓ changes. |`
- Add a row in the Settings section: `| G? | Settings tiles | Open Settings. | Each section header has a colored icon tile: General gray gear, Closed-Lid Mode indigo laptop, Limits orange gauge, Sessions green terminal, Instances blue people, About gray info. |` (use the section's next free id).

- [ ] **Step 2: Spec pointers and status**

- `specs/2026-10-13-alert-badge-design.md` §2, end of the "Badge" bullet: ` The expanded alert also gets a wash from below and a countdown bar (specs/2026-10-13-notch-polish-design.md).`
- `specs/2026-10-13-edit-counts-and-step-ticker-design.md` §3.5, first bullet: append ` Since 2026-10-13 the ticker's motion follows specs/2026-10-13-notch-polish-design.md §4.`
- `specs/2026-10-13-notch-polish-design.md`: `**Status:** Implemented`.
- `README.md`: where alerts are described, add one sentence: "An expanded alert glows from below in its color, and a thin bar shows how long it stays."

- [ ] **Step 3: Final suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no issues.
