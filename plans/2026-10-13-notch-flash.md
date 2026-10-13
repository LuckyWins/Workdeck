# Notch Flash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alerts flash the compact notch's ring (and the session dot) once in their color instead of expanding the notch with text; session and agent rows animate in and out.

**Architecture:** A pure `NotchFlash` turns the alerts of one moment into a `NotchFlashEvent` (color, whether the dot flashes, which expanded sections glow). `LimitsPresenting.flash(_:)` replaces `present(_:)`: the presenter waits for its reconcile, publishes the event on `LimitsNotchModel.flash` unless the notch is hidden, and clears it after the flash. Views animate a glow when the event's ID changes. The controller treats alerts as activity for the "When active" linger, so a hidden notch shows for 60 s. The alert queue and the alert views are removed; the alert click plumbing (project and Chats actions, Chats focus, alert texts) stays in the code for notifications that may come later.

**Tech Stack:** Swift 6 (strict concurrency, MainActor default isolation), SwiftUI, DynamicNotchKit 1.1.0, Swift Testing.

**Spec:** `specs/2026-10-13-notch-flash-design.md`

> **Superseded in part during execution** (see the spec, §2.1 and §8): limit alerts flash the ring and session alerts the dot; "needs you" also expands the notch with its text and blinks the dot after the alert closes; flashes merge instead of replacing each other; in the expanded notch the matching session's dot and account's block glow, not the section headers. The constraints and Review Focus below are kept as written for the record.

## Global Constraints

- Colors: finished → green; needs you → orange (ring and dot); first threshold → orange; second threshold → red; reset → green. Several alerts at once → the most urgent color (red > orange > green); the dot flashes when any is a session needing you, and always when the ring is not shown.
- One pulse of about 1.5 s; never repeats; no frames between flashes.
- Alert firing rules (thresholds, reset toggle, finished minimum, needs-you toggle, skipping the session's app in front) are unchanged.
- No alert text on screen, no alert clicks. The click plumbing and alert texts stay in the code, unused by the notch, for later notifications.
- Tests never touch real screens or the window server.
- Commits: none per task; the user commits after checking ("коммить"). Conventional Commits, no `Co-Authored-By`, no mention of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. A flash must not replay when DynamicNotchKit recreates the compact views (the event is cleared after the flash) — pinned in Task 1 (`theFlashClearsAfterItPlays`).
2. A limit alert while the notch is hidden in "When active" must show it and flash, not flash an invisible notch — pinned in Task 2 (`anAlertShowsAHiddenWhenActiveNotch`).
3. Session alerts arriving outside `refresh()` (through `sessions.onAlerts`) get the same linger and flash — pinned in Task 2 (`aSessionAlertFlashesAndShowsTheNotch`).
4. The second threshold is the highest configured one, whatever the user set (e.g. 70/90) — pinned in Task 1 (`colorsFollowTheConfiguredThresholds`).
5. Without a limits source the ring is not drawn, so the dot carries every flash — pinned in Task 1 (`theDotCarriesTheFlashWithoutTheRing`).

---

### Task 1: Flash events and the presenter

**Files:**
- Create: `Workdeck/Features/ClaudeCode/NotchFlash.swift`
- Modify: `Workdeck/Features/ClaudeCode/NotchPresenter.swift`, `Workdeck/Features/ClaudeCode/LimitsNotchViews.swift` (model only)
- Test: `WorkdeckTests/ClaudeCode/NotchFlashTests.swift`, `WorkdeckTests/ClaudeCode/NotchPresenterTests.swift`, `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift` (`FakePresenter` only)

**Interfaces:**
- Produces:
  - `nonisolated enum NotchFlashColor: Int, Comparable, Sendable { case green, orange, red }`
  - `nonisolated struct NotchFlashEvent: Equatable, Sendable { var id: Int; var color: NotchFlashColor; var flashesDot: Bool; var touchesLimits: Bool; var touchesSessions: Bool }`
  - `nonisolated enum NotchFlash { static func color(of alert: LimitsAlert, thresholds: [Int]) -> NotchFlashColor; static func event(for alerts: [LimitsAlert], thresholds: [Int], showsLimits: Bool, id: Int) -> NotchFlashEvent?; static let duration: Duration = .milliseconds(1500) }`
  - `LimitsNotchModel.flash: NotchFlashEvent?` (replaces `alerts`/`alert`)
  - `LimitsPresenting.flash(_ alerts: [LimitsAlert])` (replaces `present(_:)`)
  - `NotchPresenter.target(display:isHovering:hasScreen:hidesResting:)` (the `isShowingAlert` parameter is gone)
  - `NotchPresenter.init(…)` without `alertDuration`, with `flashDuration: Duration = NotchFlash.duration`

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeCode/NotchFlashTests.swift`:

```swift
import Testing
@testable import Workdeck

struct NotchFlashTests {
    let thresholds = [80, 95]

    @Test func colorsByAlert() {
        #expect(NotchFlash.color(of: .sessionFinished(project: "a", worked: 60), thresholds: thresholds) == .green)
        #expect(NotchFlash.color(of: .sessionNeedsYou(project: "a"), thresholds: thresholds) == .orange)
        #expect(NotchFlash.color(of: .threshold(window(.fiveHour, 81), threshold: 80), thresholds: thresholds) == .orange)
        #expect(NotchFlash.color(of: .threshold(window(.fiveHour, 96), threshold: 95), thresholds: thresholds) == .red)
        #expect(NotchFlash.color(of: .reset([.fiveHour]), thresholds: thresholds) == .green)
    }

    @Test func colorsFollowTheConfiguredThresholds() {
        #expect(NotchFlash.color(of: .threshold(window(.fiveHour, 91), threshold: 90), thresholds: [70, 90]) == .red)
        #expect(NotchFlash.color(of: .threshold(window(.fiveHour, 71), threshold: 70), thresholds: [70, 90]) == .orange)
    }

    @Test func aBatchTakesTheMostUrgentColor() throws {
        let event = try #require(NotchFlash.event(
            for: [.sessionFinished(project: "a", worked: 60), .threshold(window(.fiveHour, 96), threshold: 95), .sessionNeedsYou(project: "b")],
            thresholds: thresholds, showsLimits: true, id: 1
        ))
        #expect(event.color == .red)
        #expect(event.flashesDot)
        #expect(event.touchesLimits)
        #expect(event.touchesSessions)
    }

    @Test func theDotFlashesOnlyForASessionNeedingYou() throws {
        let finished = try #require(NotchFlash.event(for: [.sessionFinished(project: "a", worked: 60)], thresholds: thresholds, showsLimits: true, id: 1))
        #expect(!finished.flashesDot)
        #expect(!finished.touchesLimits)
        #expect(finished.touchesSessions)
    }

    @Test func theDotCarriesTheFlashWithoutTheRing() throws {
        let event = try #require(NotchFlash.event(for: [.reset([.fiveHour])], thresholds: thresholds, showsLimits: false, id: 1))
        #expect(event.flashesDot)
    }

    @Test func noAlertsNoFlash() {
        #expect(NotchFlash.event(for: [], thresholds: thresholds, showsLimits: true, id: 1) == nil)
    }
}
```

`NotchPresenterTests.swift`:
- `FakeNotchSurface`: delete `alertsAtExpand` and `batchesAtExpand` and their appends in `expand`.
- `makePresenter`: drop the `alertDuration` parameter and argument; pass `flashDuration: .milliseconds(60)`.
- The `target` arguments lose the `alert` column; replace the test with:

```swift
    @Test(arguments: [
        (LimitsDisplay.notch(.normal), false, true, false, NotchTarget.compact),
        (.notch(.normal), true, true, false, .expanded),
        (.hidden, true, true, false, .hidden),
        (.menuBar(text: "5h 1%", level: .normal), false, true, false, .hidden),
        (.notch(.warning), true, false, false, .hidden),
        (.notch(.normal), false, true, true, .hidden),
        (.notch(.normal), true, true, true, .hidden),
    ])
    func target(display: LimitsDisplay, hovering: Bool, screen: Bool, hidesResting: Bool, expected: NotchTarget) {
        #expect(NotchPresenter.target(display: display, isHovering: hovering, hasScreen: screen, hidesResting: hidesResting) == expected)
    }
```

- Delete the tests that rely on alerts expanding the notch: `alertExpandsThenReturnsToRestingState`, `anAlertExpandsWithoutDelay`, `alertOverFullScreenExpandsThenHides`, `noScreenMeansNoAlert`, `alertsArrivingTogetherShowAsOneBatch`, the extended-alert test around line 566, Keep the project-action test around line 581. Add:

```swift
    @Test func aFlashNeverExpands() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionNeedsYou(project: "a")])
        #expect(presenter.model.flash == nil || presenter.model.flash?.color == .orange)
        await settle(presenter)
        #expect(!surface.calls.contains("expand"))
        #expect(presenter.appliedTarget == .compact)
    }

    @Test func alertsTogetherMakeOneFlash() async throws {
        let (presenter, _) = makePresenter(flashDuration: .seconds(5))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.sessionFinished(project: "a", worked: 60), .threshold(window(.fiveHour, 96), threshold: 95)])
        let deadline = Date().addingTimeInterval(2)
        while presenter.model.flash == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let flash = try #require(presenter.model.flash)
        #expect(flash.color == .red)
    }

    @Test func theFlashClearsAfterItPlays() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.flash([.reset([.fiveHour])])
        await settle(presenter)
        #expect(presenter.model.flash == nil)
    }

    @Test func aHiddenNotchDoesNotFlash() async {
        var seen: [NotchFlashEvent?] = []
        let (presenter, _) = makePresenter()
        presenter.show(state(.hidden))
        await settle(presenter)
        presenter.flash([.reset([.fiveHour])])
        seen.append(presenter.model.flash)
        await settle(presenter)
        seen.append(presenter.model.flash)
        #expect(seen.allSatisfy { $0 == nil })
    }

    @Test func noScreenNoFlash() async {
        let (presenter, _) = makePresenter(screen: nil)
        presenter.show(state(.notch(.normal)))
        presenter.flash([.reset([.fiveHour])])
        await settle(presenter)
        #expect(presenter.model.flash == nil)
    }
```

Rename `makePresenter`'s new parameter `flashDuration: Duration = .milliseconds(60)` and pass it as `flashDuration: flashDuration`.

`ClaudeCodeControllerTests.swift`, `FakePresenter`: replace `present(_:)` with

```swift
    private(set) var flashes: [[LimitsAlert]] = []
    func flash(_ alerts: [LimitsAlert]) {
        flashes.append(alerts)
        self.alerts += alerts
    }
```

(`alerts` stays, so existing expectations on `presenter.alerts` keep working.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchFlashTests -only-testing:WorkdeckTests/NotchPresenterTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors: `cannot find 'NotchFlash'`, `has no member 'flash'`, `extra argument 'flashDuration'`.

- [ ] **Step 3: Implement**

`Workdeck/Features/ClaudeCode/NotchFlash.swift`:

```swift
import Foundation

/// How urgent a flash is; the most urgent alert of a moment colors it (spec §2.1).
nonisolated enum NotchFlashColor: Int, Comparable, Sendable {
    case green
    case orange
    case red

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One flash of the notch; a new `id` restarts the animation even with the same color.
nonisolated struct NotchFlashEvent: Equatable, Sendable {
    var id: Int
    var color: NotchFlashColor
    /// The session dot flashes too: a session needs you, or the ring is not shown.
    var flashesDot: Bool
    /// Which expanded sections' headers glow when the notch is open.
    var touchesLimits: Bool
    var touchesSessions: Bool
}

nonisolated enum NotchFlash {
    static let duration: Duration = .milliseconds(1500)

    static func color(of alert: LimitsAlert, thresholds: [Int]) -> NotchFlashColor {
        switch alert {
        case .sessionFinished, .reset: .green
        case .sessionNeedsYou: .orange
        case let .threshold(_, threshold, _):
            thresholds.count > 1 && threshold >= (thresholds.max() ?? .max) ? .red : .orange
        }
    }

    static func event(for alerts: [LimitsAlert], thresholds: [Int], showsLimits: Bool, id: Int) -> NotchFlashEvent? {
        guard let color = alerts.map({ color(of: $0, thresholds: thresholds) }).max() else { return nil }
        let needsYou = alerts.contains { if case .sessionNeedsYou = $0 { true } else { false } }
        return NotchFlashEvent(
            id: id,
            color: color,
            flashesDot: needsYou || !showsLimits,
            touchesLimits: alerts.contains { !isSessionAlert($0) },
            touchesSessions: alerts.contains(where: isSessionAlert)
        )
    }

    private static func isSessionAlert(_ alert: LimitsAlert) -> Bool {
        switch alert {
        case .sessionFinished, .sessionNeedsYou: true
        case .threshold, .reset: false
        }
    }
}
```

`LimitsNotchViews.swift`, `LimitsNotchModel`: replace `alerts` and `alert` with

```swift
    /// The flash playing now; cleared when it ends so recreated views do not replay it.
    var flash: NotchFlashEvent?
```

and keep `onActivateProject` and `onOpenChats`: the click plumbing stays for later notifications.

`NotchPresenter.swift`:
- `LimitsPresenting`: replace `present(_ alert: LimitsAlert)` and its doc with

```swift
    /// Flashes the notch once for alerts that happened together; never expands it (spec §2).
    func flash(_ alerts: [LimitsAlert])
```

- Remove `alertDuration`, `isShowingAlert`, `pendingAlerts`, `isAlertExtended`, `alertTask` and `present(_:)`. Add `private let flashDuration: Duration`, `private var flashTask: Task<Void, Never>?`, `private var flashCount = 0`; init parameter `flashDuration: Duration = NotchFlash.duration` in place of `alertDuration`; `isBusy` counts `flashTask` instead of `alertTask`.
- `target` drops `isShowingAlert`:

```swift
    static func target(display: LimitsDisplay, isHovering: Bool, hasScreen: Bool, hidesResting: Bool = false) -> NotchTarget {
        guard hasScreen, case .notch = display, !hidesResting else { return .hidden }
        return isHovering ? .expanded : .compact
    }
```

and `reconcileOnce` stops passing it (`mayRest` becomes `if case .notch = model.state.display { true } else { false }`).
- Add:

```swift
    func flash(_ alerts: [LimitsAlert]) {
        flashCount += 1
        guard let event = NotchFlash.event(for: alerts, thresholds: model.state.thresholds, showsLimits: model.state.showsLimits, id: flashCount) else { return }
        flashTask?.cancel()
        flashTask = Task {
            // Let the reconcile show a notch the alert just made visible, then flash only what is on screen.
            while reconcileTask != nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled, appliedTarget != .hidden else {
                flashTask = nil
                return
            }
            model.flash = event
            try? await Task.sleep(for: flashDuration)
            if model.flash?.id == event.id {
                model.flash = nil
            }
            flashTask = nil
        }
    }
```

- `screenParametersChanged`, `hoverChanged` and the peek code no longer read alert state; remove any remaining `isShowingAlert` use.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command.
Expected: `** TEST SUCCEEDED **`. (If `ClaudeCodeController` fails to build on `presenter.present`, change its two call sites now to `presenter.flash([alert])` / `presenter.flash(alerts)`; Task 2 reworks them.)

### Task 2: Alerts in the controller

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift`
- Test: `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift`

**Interfaces:**
- Consumes: `LimitsPresenting.flash(_:)` (Task 1); the linger from the "When active" feature (`workEndedAt`, `lingers(isActive:)`).

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func anAlertShowsAHiddenWhenActiveNotch() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.state.display == .hidden)
        try writeUsage(fiveHour: 82)
        store.reload()
        #expect(controller.state.display == .notch(.warning))
        #expect(presenter.flashes.last == [.threshold(window(.fiveHour, 82), threshold: 80)])
    }

    @Test func aResetFlashesAndLingers() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 85)
        var now = fixedNow
        let (controller, store) = makeController(clock: { now })
        controller.start()
        store.reload()
        // The window resets: below the threshold, the notch would hide at once without the linger.
        try UsageSnapshotFile.write(UsageSnapshot(capturedAt: fixedNow, fiveHour: window(.fiveHour, 2, resetsIn: 5 * 3600), sevenDay: nil), to: fileURL)
        store.reload()
        #expect(presenter.flashes.last == [.reset([.fiveHour])])
        #expect(controller.state.display == .notch(.normal))
        now = fixedNow.addingTimeInterval(61)
        controller.refresh()
        #expect(controller.state.display == .hidden)
    }

    @Test func aSessionAlertFlashesAndShowsTheNotch() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        settings.notifyWhenNeedsYou = true
        try writeUsage(fiveHour: 10)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        addLiveSession(waiting: true)
        controller.sessions.store.reload()
        #expect(presenter.flashes.contains { $0.contains(.sessionNeedsYou(project: "Workdeck")) })
        #expect(controller.state.display == .notch(.normal))
    }
```

If the session alert needs the frontmost app to differ (alerts skip the session's own app), the test's `frontmostBundleID: { nil }` already makes it differ; if `notifyWhenNeedsYou` gating needs a settled store, follow the existing needs-you test in this file.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ClaudeCodeControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `anAlertShowsAHiddenWhenActiveNotch` fails on the display (`.hidden` would be shown before the alert), `aResetFlashesAndLingers` fails on `.notch(.normal)`.

- [ ] **Step 3: Implement**

`ClaudeCodeController.swift`:
- In `start()`, replace the `sessions.onAlerts` handler:

```swift
        sessions.onAlerts = { [weak self] alerts in
            guard let self, !alerts.isEmpty else { return }
            noteAlerts()
            refresh()
            flash(alerts)
        }
```

- At the top of `refresh()`, after `sessions.updateKeepAwake()`:

```swift
        // Limit alerts come first: in "When active" an alert counts as activity, so a hidden notch shows (spec §2.3).
        let limitAlerts = limits.takeAlerts()
        if !limitAlerts.isEmpty {
            noteAlerts()
        }
```

and at the end replace the `for alert in limits.takeAlerts() { … presenter.present(alert) }` loop with `flash(limitAlerts)`.
- Add:

```swift
    /// An alert restarts the "When active" linger, as if work had just ended.
    private func noteAlerts() {
        workEndedAt = clock()
        lingerTask?.cancel()
        lingerTask = nil
    }

    private func flash(_ alerts: [LimitsAlert]) {
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            WorkdeckLog.alerts.notice("\(LimitsText.alertTitle(alert, showsAccount: true), privacy: .public), flashed")
        }
        presenter.flash(alerts)
    }
```

`lingers(isActive:)` already returns true while `workEndedAt` is less than `linger` ago and schedules the ending refresh.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Full suite**

Run: the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`.

### Task 3: Flash and list animations in the views

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/LimitsNotchViews.swift`, `Workdeck/Features/ClaudeCode/Sessions/SessionsNotchViews.swift`, `Workdeck/Features/ClaudeCode/TerminalStyle.swift`

**Interfaces:**
- Consumes: `LimitsNotchModel.flash`, `NotchFlashEvent`, `NotchFlashColor` (Task 1).

This task is SwiftUI animation; its gate is a clean build, the full suite, and the user's probe.

- [ ] **Step 1: The flash color and glow modifier**

`TerminalStyle.swift`:

```swift
extension NotchFlashColor {
    var color: Color {
        switch self {
        case .green: .green
        case .orange: .orange
        case .red: .red
        }
    }
}

/// Glows once in the flash color when a new flash plays (spec §2.2): 0.25 s in, 0.45 s hold, 0.8 s out.
struct FlashGlow: ViewModifier {
    let event: NotchFlashEvent?
    let applies: Bool
    var radius: CGFloat = 5
    @State private var glow = 0.0

    func body(content: Content) -> some View {
        content
            .shadow(color: (event?.color.color ?? .clear).opacity(glow), radius: radius)
            .shadow(color: (event?.color.color ?? .clear).opacity(glow * 0.6), radius: radius / 2)
            .task(id: event?.id) {
                guard event != nil, applies else { return }
                withAnimation(.easeOut(duration: 0.25)) { glow = 1 }
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.easeIn(duration: 0.8)) { glow = 0 }
            }
    }
}

extension View {
    func flashGlow(_ event: NotchFlashEvent?, applies: Bool = true, radius: CGFloat = 5) -> some View {
        modifier(FlashGlow(event: event, applies: applies, radius: radius))
    }
}
```

- [ ] **Step 2: Ring and dot**

`UsageRing` gains `var flash: NotchFlashEvent? = nil` and, on the arc, a colored overlay during the flash:

```swift
    @State private var tint = 0.0

    // in body, after the arc:
            Circle()
                .stroke(flash?.color.color ?? .clear, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .opacity(tint)
    // on the ZStack:
        .flashGlow(flash, radius: 4)
        .task(id: flash?.id) {
            guard flash != nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { tint = 1 }
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeIn(duration: 0.8)) { tint = 0 }
        }
```

`LimitsCompactLeading` passes `flash: model.flash` to `UsageRing`.

`SessionsCounter` gains `var flash: NotchFlashEvent? = nil`; the `●` text gets `.flashGlow(flash, applies: flash?.flashesDot == true, radius: 4)` and, during a flash with `flashesDot`, the flash color: keep a `@State private var dotTint = 0.0` animated like `tint` above and render the dot as `Text("●").foregroundStyle(color).overlay(Text("●").foregroundStyle(flash?.color.color ?? .clear).opacity(dotTint))`. When there is no active session the dot is not drawn; a dot-only flash (no ring) then shows nothing extra, which is acceptable. `LimitsCompactTrailing` passes `flash: model.flash`.

- [ ] **Step 3: Expanded headers**

In `LimitsExpandedView.details`, add `.flashGlow(model.flash, applies: model.flash?.touchesLimits == true)` to the first limits header (the `accountsHeader(…)` call and the first `TerminalHeader` of the blocks, i.e. when `isFirst`), and `.flashGlow(model.flash, applies: model.flash?.touchesSessions == true)` to the sessions `TerminalHeader`.

- [ ] **Step 4: Remove the alert views**

In `LimitsExpandedView`: `body` renders `details` only; delete `hoveredAlert`, `alertView`, `openable`, `clickTarget`, `batchView`, `maxBatchLines` and `alertColor`. Keep the model's `onActivateProject`/`onOpenChats`, the presenter's `setProjectAction`/`setChatsAction`, the controller wiring, `ChatsController.focus(onChat:)` and the alert texts in `LimitsText`: they are kept for notifications that may come later (the user's call).

- [ ] **Step 5: List transitions**

`SessionsList`: on each row's `Button` inside `ForEach(state.rows)` add `.transition(.opacity.combined(with: .move(edge: .top)))`, and on the `VStack` add `.animation(.snappy, value: state.rows.map(\.id))`. Do the same for agent cards inside a row (their `ForEach`, keyed by agent ID) with `.animation(.snappy, value: row.agents.map(\.id))` on their container. (Use the property names the file already uses for agent IDs.)

- [ ] **Step 6: Build and full suite**

Run: the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Probe with the user (spec §6)**

Ask the user to `make install` and check on the MacBook and on the monitor: lower the first threshold below the usage (threshold flash), turn on "Notify when a session needs you" and trigger a permission prompt while another app is in front (orange ring and dot), let a session finish after the minimum (green ring). Check that the ring's glow is not clipped, the flash is noticeable but calm, and the ring's fill animates when the percent changes. Record the answer in spec §8. If the glow is clipped, drop the `flashGlow` on the ring and keep the color overlay only; ledger it.

### Task 4: Documentation

**Files:**
- Modify: `README.md`, `docs/testing.md`, `specs/2026-10-09-claude-accounts-design.md`, `specs/2026-10-06-claude-sessions-design.md`, `specs/2026-10-13-notch-flash-design.md`

- [ ] **Step 1: README**

Replace "Alerts at two configurable thresholds … resets (one alert when both windows reset together)." with:

```
- Alerts at two configurable thresholds (80 % and 95 % by default) and, optionally, when a limit you came close to resets. An alert flashes the compact notch's ring once in its color (orange, red, or green for a reset) instead of opening the notch; hover to see the details.
```

In the Sessions paragraph, replace the description of finished and needs-you alerts expanding the notch with: "**Notify when a session finishes** and **Notify when a session needs you** flash the ring green or the ring and the session dot orange." In the accounts paragraph, delete "clicking one opens Chats on that account's latest session."

- [ ] **Step 2: Manual checklist**

`docs/testing.md`: in L5, L9, S11, S12, A4 change "expands …"/"appears …" expectations to "the compact ring flashes <color> once; the notch does not expand"; in S17 delete the alert-click half; add after the last `S` row:

```
| S20 | List transitions | Start a session and an agent, then let the agent finish and the session end. | Rows slide and fade in when they appear and fade out when they leave; nothing animates while nothing changes. |
```

- [ ] **Step 3: Specs**

Accounts spec §4.4, last two bullets: replace "Clicking a limit alert opens the Chats window …" with "Alerts flash the notch and are not clickable (`specs/2026-10-13-notch-flash-design.md`)." Sessions spec: next to its alert section add the same sentence. Flash spec: **Status** → `Implemented`.

- [ ] **Step 4: Full suite and hand over**

Run: the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`. Ask the user to check S20 and the flash rows; no commit until they say "коммить".
