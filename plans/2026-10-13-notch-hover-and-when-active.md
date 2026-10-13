# Notch Hover and "When Active" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delay notch hover changes (0.25 s in, 0.5 s out) and replace "Only near limits" with "When active": visible while sessions are active, near limits, for 60 s after work ends, and while the pointer peeks at the notch's place.

**Architecture:** `LimitsPresentation.display` decides visibility from the mode, the limit level, an "active or lingering" flag and a "peeking" flag. `ClaudeCodeController` tracks when work last ended, schedules a refresh when the linger runs out, and learns about peeking from the presenter. `NotchPresenter` delays DynamicNotchKit's hover signal and, while the state says the notch can be peeked at, runs a global pointer monitor and reports peeks after the same delays.

**Tech Stack:** Swift 6 (strict concurrency, MainActor default isolation), SwiftUI, AppKit, DynamicNotchKit 1.1.0, Swift Testing.

**Spec:** `specs/2026-10-13-notch-hover-and-when-active-design.md`

## Global Constraints

- Mode titles "Always" and "When active"; `whenActive` keeps the raw value `"nearLimits"`.
- Hover enter delay 0.25 s, exit delay 0.5 s; alerts expand without delay. Linger 60 s. Peek zone: the notch rectangle widened by 60 pt on each side.
- The pointer monitor needs no permission, observes mouse-moved only, and runs only while the notch can be peeked at or is being peeked at.
- The menu bar text mode keeps today's behavior ("When active" shows text only near limits).
- Tests never touch real global event monitors; presenter tests inject short delays.
- Commits: none per task; the user commits after checking ("коммить"). Conventional Commits, no `Co-Authored-By`, no mention of AI tools.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; one suite adds `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. A session that goes idle and another that starts within the linger keeps the notch visible without a hide/show blink — pinned in Task 2 (`aNewSessionDuringTheLingerKeepsTheNotch`).
2. Rapid hover in/out (the existing overlap test) must still end compact and never overlap DynamicNotchKit calls with the delays on — pinned by the existing `quickHoverEndsCompactWithoutOverlappingCalls` in Task 3, run with the delays.
3. The pointer monitor must stop when the mode returns to "Always" or the notch becomes visible for another reason and the pointer is not peeking — pinned in Task 3 (`theMonitorStopsWhenNotPeekable`).
4. A full-screen app on the virtual notch's display: peeking does not show the notch — pinned in Task 3 (`peekingDoesNotShowOverFullScreen`).
5. A stored `"nearLimits"` reads as "When active" — pinned in Task 1 (`theStoredNearLimitsModeReadsAsWhenActive`).

---

### Task 1: The "When active" mode and visibility rule

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/LimitsPresentation.swift`
- Test: `WorkdeckTests/ClaudeCode/LimitsPresentationTests.swift`, `WorkdeckTests/ClaudeCode/ClaudeCodeSettingsTests.swift`, and every test that names `.nearLimits` (`ClaudeCodeControllerTests.swift`, `Accounts/AccountsCompositionTests.swift`)

**Interfaces:**
- Produces:
  - `LimitsDisplayMode.whenActive` (raw value `"nearLimits"`, title "When active"); `nearLimits` is removed
  - `LimitsPresentation.display(isEnabled:isConnected:mode:hasNotchScreen:pressing:hasData:thresholds:hasSessions:isPeeking:label:)` — `hasSessions` now means "a session is active or the linger runs"; new `isPeeking: Bool = false`
  - `LimitsViewState.isPeekable: Bool = false`

- [ ] **Step 1: Write the failing tests**

Rename every `.nearLimits` in the test files to `.whenActive` (`sed -i '' 's/\.nearLimits/.whenActive/g'` on the five test files listed above).

`ClaudeCodeSettingsTests.swift`:

```swift
    @Test func theStoredNearLimitsModeReadsAsWhenActive() {
        let defaults = makeDefaults()
        defaults.set("nearLimits", forKey: "claudeLimits.mode")
        #expect(ClaudeCodeSettings(defaults: defaults).mode == .whenActive)
        #expect(LimitsDisplayMode.whenActive.title == "When active")
    }
```

`LimitsPresentationTests.swift`: give the `display` helper `active: Bool = false, peeking: Bool = false` passed as `hasSessions: active, isPeeking: peeking`, and add:

```swift
    @Test func whenActiveShowsTheNotchWhileSomethingHappens() {
        let normal = window(.fiveHour, 10)
        #expect(display(mode: .whenActive, pressing: normal) == .hidden)
        #expect(display(mode: .whenActive, pressing: normal, active: true) == .notch(.normal))
        #expect(display(mode: .whenActive, pressing: normal, peeking: true) == .notch(.normal))
        #expect(display(mode: .whenActive, pressing: window(.fiveHour, 81)) == .notch(.warning))
        // Peeking never shows text in the menu bar.
        #expect(display(mode: .whenActive, notch: false, pressing: normal, peeking: true) == .hidden)
    }
```

`ClaudeCodeControllerTests.swift`, in the renamed `sessionsKeepTheNotchInNearLimitsMode` (rename it `sessionsKeepTheNotchWhenActive`): the limits part now shows whenever the notch is visible, so change `#expect(!state.showsLimits)` to `#expect(state.showsLimits)`. (This expectation is satisfied in Task 2.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/LimitsPresentationTests -only-testing:WorkdeckTests/ClaudeCodeSettingsTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors: `type 'LimitsDisplayMode' has no member 'whenActive'`, `extra argument 'isPeeking'`.

- [ ] **Step 3: Implement**

`LimitsPresentation.swift`:

```swift
nonisolated enum LimitsDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case always
    /// Visible while something happens, for a minute after, and while peeked at (spec §3). Keeps the raw value of
    /// the "Only near limits" mode it replaced, so a saved choice carries over.
    case whenActive = "nearLimits"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always"
        case .whenActive: "When active"
        }
    }
}
```

In `LimitsViewState`, after `showsLimits`:

```swift
    /// "When active" hides the notch for now, so pointing at its place may show it (spec §5).
    var isPeekable = false
```

and update the `showsLimits` doc to "False when the notch is shown only for sessions (no limits source)."

`display`:

```swift
    /// `hasSessions`: a session is active, or worked less than a minute ago ("When active" linger).
    /// `isPeeking`: the pointer points at the hidden notch's place.
    static func display(
        isEnabled: Bool,
        isConnected: Bool,
        mode: LimitsDisplayMode,
        hasNotchScreen: Bool,
        pressing: UsageWindow?,
        hasData: Bool,
        thresholds: [Int],
        hasSessions: Bool = false,
        isPeeking: Bool = false,
        label: String? = nil
    ) -> LimitsDisplay {
        guard isEnabled else { return .hidden }
        let level = displayLevel(pressing: pressing, hasData: hasData, thresholds: thresholds)
        let limitsVisible = showsLimits(isConnected: isConnected, mode: mode, level: level)
        if hasNotchScreen {
            return limitsVisible || hasSessions || isPeeking ? .notch(level) : .hidden
        }
        guard limitsVisible else { return .hidden }
        return .menuBar(text: (label.map { "\($0) " } ?? "") + compactText(pressing: pressing, hasData: hasData), level: level)
    }
```

`showsLimits`: replace `.nearLimits` with `.whenActive` and its doc with "Whether the limits alone keep the indicator visible: a source is on and "When active" is not keeping it quiet below the first threshold."

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command.
Expected: `** TEST SUCCEEDED **`.

### Task 2: Linger and peeking in the controller

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift`, `Workdeck/Features/ClaudeCode/NotchPresenter.swift` (protocol only)
- Test: `WorkdeckTests/ClaudeCode/ClaudeCodeControllerTests.swift`

**Interfaces:**
- Consumes: `display(…hasSessions:isPeeking:…)`, `LimitsViewState.isPeekable`, `.whenActive` (Task 1).
- Produces:
  - `LimitsPresenting.setPeekAction(_ action: @escaping (Bool) -> Void)`
  - `ClaudeCodeController.init(…, clock: @escaping () -> Date = { Date() }, linger: TimeInterval = 60)`

- [ ] **Step 1: Write the failing tests**

`FakePresenter`:

```swift
    private(set) var peekAction: ((Bool) -> Void)?
    func setPeekAction(_ action: @escaping (Bool) -> Void) {
        peekAction = action
    }
```

`makeController` gains `clock: @escaping () -> Date = { fixedNow }, linger: TimeInterval = 60` passed to `ClaudeCodeController(…, clock: clock, linger: linger)`. Add:

```swift
    @Test func theNotchLingersAMinuteAfterWorkEnds() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "s1"), to: sessionsDirectory)
        var now = fixedNow
        let (controller, store) = makeController(clock: { now })
        controller.start()
        store.reload()
        #expect(controller.state.display == .notch(.normal))
        writeSessionEvent(hookEvent(.stop, at: 2, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.refresh()
        #expect(controller.state.display == .notch(.normal))
        now = fixedNow.addingTimeInterval(59)
        controller.refresh()
        #expect(controller.state.display == .notch(.normal))
        now = fixedNow.addingTimeInterval(61)
        controller.refresh()
        #expect(controller.state.display == .hidden)
        #expect(controller.state.isPeekable)
    }

    @Test func aNewSessionDuringTheLingerKeepsTheNotch() throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "s1"), to: sessionsDirectory)
        var now = fixedNow
        let (controller, store) = makeController(clock: { now })
        controller.start()
        store.reload()
        writeSessionEvent(hookEvent(.stop, at: 2, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.refresh()
        now = fixedNow.addingTimeInterval(30)
        controller.refresh()
        #expect(controller.state.display == .notch(.normal))
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 31, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.refresh()
        now = fixedNow.addingTimeInterval(75)
        controller.refresh()
        #expect(controller.state.display == .notch(.normal))
    }

    @Test(.timeLimit(.minutes(1)))
    func theLingerEndsWithARefresh() async throws {
        connector.status = .connected
        hooksConnector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        addLiveSession()
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1, session: "s1"), to: sessionsDirectory)
        let (controller, store) = makeController(clock: { Date() }, linger: 0.05)
        controller.start()
        store.reload()
        writeSessionEvent(hookEvent(.stop, at: 2, session: "s1"), to: sessionsDirectory)
        controller.sessions.store.reload()
        controller.refresh()
        #expect(controller.state.display == .notch(.normal))
        while controller.state.display != .hidden {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func peekingShowsTheHiddenNotch() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.mode = .whenActive
        try writeUsage(fiveHour: 10)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(controller.state.display == .hidden)
        #expect(controller.state.isPeekable)
        presenter.peekAction?(true)
        #expect(controller.state.display == .notch(.normal))
        #expect(!controller.state.isPeekable)
        presenter.peekAction?(false)
        #expect(controller.state.display == .hidden)
    }

    @Test func alwaysIsNeverPeekable() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 10)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(!controller.state.isPeekable)
    }
```

If `addLiveSession()` or the `stop` handling in the existing helpers needs a PID, follow `sessionUpdatesAreIgnoredWithoutHooks` (line ~540) which already writes `userPromptSubmit` then `stop`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ClaudeCodeControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors: `has no member 'setPeekAction'` (FakePresenter conformance), `extra arguments 'clock', 'linger'`.

- [ ] **Step 3: Implement**

`NotchPresenter.swift`, `LimitsPresenting`:

```swift
    /// Called with true when the pointer has rested on the hidden notch's place, false when it has left (spec §5).
    func setPeekAction(_ action: @escaping (Bool) -> Void)
```

and in `NotchPresenter` a stub storing it (Task 3 uses it):

```swift
    private var onPeekChange: ((Bool) -> Void)?

    func setPeekAction(_ action: @escaping (Bool) -> Void) {
        onPeekChange = action
    }
```

`ClaudeCodeController.swift`:
- Stored properties:

```swift
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let linger: TimeInterval
    /// When the last active session went idle; the "When active" notch stays `linger` seconds after it.
    @ObservationIgnored private var workEndedAt: Date?
    @ObservationIgnored private var wasActive = false
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var isPeeking = false
```

- `init` parameters `clock: @escaping () -> Date = { Date() }, linger: TimeInterval = 60` after `cameraHousings`, assigned.
- In `start()`, next to the other presenter actions:

```swift
        presenter.setPeekAction { [weak self] peeking in
            guard let self else { return }
            isPeeking = peeking
            refresh()
        }
```

- In `refresh()`, before `let display = …`:

```swift
        let isActive = sessionsView.activeCount > 0
        let isLingering = lingers(isActive: isActive)
        let hasNotchScreen = NotchPresenter.targetIndex(cameraHousings: cameraHousings(), notchless: settings.notchlessDisplay) != nil
```

pass `hasNotchScreen: hasNotchScreen`, `hasSessions: isActive || isLingering`, `isPeeking: isPeeking`; after it:

```swift
        let isPeekable = settings.mode == .whenActive && display == .hidden && settings.isEnabled && hasNotchScreen && hasAnySource
```

and in `LimitsViewState(…)` set `showsLimits: limits.hasDataSource` and `isPeekable: isPeekable` (argument after `showsLimits`).
- Add:

```swift
    /// "When active" keeps the notch `linger` seconds after the last active session goes idle (spec §3).
    private func lingers(isActive: Bool) -> Bool {
        let now = clock()
        if isActive {
            wasActive = true
            lingerTask?.cancel()
            lingerTask = nil
            return false
        }
        if wasActive {
            wasActive = false
            workEndedAt = now
        }
        guard let workEndedAt else { return false }
        let remaining = linger - now.timeIntervalSince(workEndedAt)
        guard remaining > 0 else { return false }
        if lingerTask == nil {
            lingerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, let self else { return }
                lingerTask = nil
                refresh()
            }
        }
        return true
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Full suite**

Run: the Global Constraints test command.
Expected: `** TEST SUCCEEDED **` (other `LimitsPresenting` fakes, if any, get the same `setPeekAction` stub).

### Task 3: Hover delays and the peek monitor in the presenter

**Files:**
- Create: `Workdeck/Features/ClaudeCode/NotchPeek.swift`
- Modify: `Workdeck/Features/ClaudeCode/NotchPresenter.swift`
- Test: `WorkdeckTests/ClaudeCode/NotchPresenterTests.swift`, `WorkdeckTests/ClaudeCode/NotchPeekTests.swift`

**Interfaces:**
- Consumes: `LimitsViewState.isPeekable`, `setPeekAction` (Task 2), `NotchScreen` (virtual notch).
- Produces:
  - `protocol PointerMonitoring: AnyObject { func start(_ onMove: @escaping (CGPoint) -> Void); func stop() }`, `GlobalPointerMonitor`
  - `enum NotchPeekZone { static let wingWidth: CGFloat = 60; static func rect(screenFrame: CGRect, notchSize: CGSize) -> CGRect; static func rect(for screen: NotchScreen) -> CGRect }`
  - `NotchPresenter.init(…, pointer: any PointerMonitoring = GlobalPointerMonitor(), hoverEnterDelay: Duration = .milliseconds(250), hoverExitDelay: Duration = .milliseconds(500), …)`

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeCode/NotchPeekTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import Workdeck

struct NotchPeekTests {
    let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    @Test func theZoneIsTheNotchWithWings() {
        let zone = NotchPeekZone.rect(screenFrame: frame, notchSize: CGSize(width: 300, height: 25))
        #expect(zone == CGRect(x: 1280 - 150 - 60, y: 1440 - 25, width: 420, height: 25))
        #expect(zone.contains(CGPoint(x: 1280, y: 1430)))
        #expect(zone.contains(CGPoint(x: 1075, y: 1430)))
        #expect(!zone.contains(CGPoint(x: 1060, y: 1430)))
        #expect(!zone.contains(CGPoint(x: 1280, y: 1400)))
    }

    @Test func aScreenWithAnOffsetKeepsItsZone() {
        let right = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let zone = NotchPeekZone.rect(screenFrame: right, notchSize: CGSize(width: 300, height: 24))
        #expect(zone.midX == right.midX)
        #expect(zone.maxY == right.maxY)
    }
}
```

`NotchPresenterTests.swift`: add a fake next to `FakeFullScreen`:

```swift
@MainActor
final class FakePointer: PointerMonitoring {
    private(set) var isRunning = false
    private var onMove: ((CGPoint) -> Void)?

    func start(_ onMove: @escaping (CGPoint) -> Void) {
        isRunning = true
        self.onMove = onMove
    }

    func stop() {
        isRunning = false
        onMove = nil
    }

    func move(to point: CGPoint) {
        onMove?(point)
    }
}
```

give the struct `let pointer = FakePointer()`, pass `pointer: pointer, hoverEnterDelay: .milliseconds(40), hoverExitDelay: .milliseconds(80)` in `makePresenter`, and add:

```swift
    private func peekableState() -> LimitsViewState {
        var state = state(.hidden)
        state.isPeekable = true
        return state
    }

    @Test func aBriefHoverDoesNotExpand() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        try? await Task.sleep(for: .milliseconds(10))
        surface.onHoverChange?(false)
        await settle(presenter)
        #expect(!surface.calls.contains("expand"))
        #expect(presenter.appliedTarget == .compact)
    }

    @Test func aBriefExitDoesNotCollapse() async {
        let (presenter, _) = makePresenter()
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(presenter.appliedTarget == .expanded)
        surface.onHoverChange?(false)
        try? await Task.sleep(for: .milliseconds(20))
        surface.onHoverChange?(true)
        await settle(presenter)
        #expect(presenter.appliedTarget == .expanded)
        #expect(surface.calls.filter { $0 == "compact" }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func anAlertExpandsWithoutDelay() async {
        let (presenter, _) = makePresenter(alertDuration: .seconds(5))
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        presenter.present(.reset([.fiveHour]))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(presenter.appliedTarget == .expanded)
    }

    @Test func peekingReportsAfterTheDelaysAndStops() async throws {
        var peeks: [Bool] = []
        let (presenter, _) = makePresenter()
        presenter.setPeekAction { peeks.append($0) }
        presenter.show(peekableState())
        await settle(presenter)
        #expect(pointer.isRunning)
        let screen = try #require(NSScreen.screens.first)
        let zone = NotchPeekZone.rect(for: NotchScreen(screen: screen, isVirtual: false))
        pointer.move(to: CGPoint(x: zone.midX, y: zone.midY))
        await settle(presenter)
        #expect(peeks == [true])
        pointer.move(to: CGPoint(x: zone.midX, y: zone.minY - 200))
        await settle(presenter)
        #expect(peeks == [true, false])
    }

    @Test func aPassingPointerDoesNotPeek() async throws {
        var peeks: [Bool] = []
        let (presenter, _) = makePresenter()
        presenter.setPeekAction { peeks.append($0) }
        presenter.show(peekableState())
        await settle(presenter)
        let screen = try #require(NSScreen.screens.first)
        let zone = NotchPeekZone.rect(for: NotchScreen(screen: screen, isVirtual: false))
        pointer.move(to: CGPoint(x: zone.midX, y: zone.midY))
        try? await Task.sleep(for: .milliseconds(10))
        pointer.move(to: CGPoint(x: zone.midX, y: zone.minY - 200))
        await settle(presenter)
        #expect(peeks.isEmpty)
    }

    @Test func theMonitorStopsWhenNotPeekable() async {
        let (presenter, _) = makePresenter()
        presenter.show(peekableState())
        await settle(presenter)
        #expect(pointer.isRunning)
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(!pointer.isRunning)
    }

    @Test func peekingDoesNotShowOverFullScreen() async {
        fullScreen.isOn = true
        let (presenter, _) = makePresenter(virtual: true)
        // The controller answers a peek with a visible notch; full screen still keeps it hidden.
        presenter.show(state(.notch(.normal)))
        await settle(presenter)
        #expect(presenter.appliedTarget == .hidden)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchPresenterTests -only-testing:WorkdeckTests/NotchPeekTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors: `cannot find type 'PointerMonitoring'`, `cannot find 'NotchPeekZone'`, `extra arguments 'pointer', 'hoverEnterDelay', 'hoverExitDelay'`.

- [ ] **Step 3: Implement**

`Workdeck/Features/ClaudeCode/NotchPeek.swift`:

```swift
import AppKit

/// Reports where the pointer moves, so a hidden notch can be peeked at (spec §5). It observes mouse-moved
/// events only: no permission, no clicks, no keys.
protocol PointerMonitoring: AnyObject {
    func start(_ onMove: @escaping (CGPoint) -> Void)
    func stop()
}

/// Global and local mouse-moved monitors: global events come while another app is active, local ones while a
/// Workdeck window is.
final class GlobalPointerMonitor: PointerMonitoring {
    private var monitors: [Any] = []

    func start(_ onMove: @escaping (CGPoint) -> Void) {
        stop()
        let report = { MainActor.assumeIsolated { onMove(NSEvent.mouseLocation) } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in report() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in report(); return event }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

/// Where pointing shows a hidden notch: the notch's rectangle at the top center, widened for its compact wings.
nonisolated enum NotchPeekZone {
    static let wingWidth: CGFloat = 60
    /// DynamicNotchKit's width for a display without a camera housing.
    static let virtualNotchWidth: CGFloat = 300
    static let minimumHeight: CGFloat = 24

    static func rect(screenFrame: CGRect, notchSize: CGSize) -> CGRect {
        let width = notchSize.width + 2 * wingWidth
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - notchSize.height, width: width, height: notchSize.height)
    }

    @MainActor
    static func rect(for target: NotchScreen) -> CGRect {
        let screen = target.screen
        let size: CGSize
        if !target.isVirtual, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            size = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            size = CGSize(width: virtualNotchWidth, height: max(screen.frame.maxY - screen.visibleFrame.maxY, minimumHeight))
        }
        return rect(screenFrame: screen.frame, notchSize: size)
    }
}
```

`NotchPresenter.swift`:
- Stored: `private let pointer: any PointerMonitoring`, `private let hoverEnterDelay: Duration`, `private let hoverExitDelay: Duration`, `private var hoverTask: Task<Void, Never>?`, `private var peekTask: Task<Void, Never>?`, `private var isPointerRunning = false`, `private var isPointerInZone = false`, `private var isPeeking = false`.
- `init` parameters after `fullScreen`: `pointer: any PointerMonitoring = GlobalPointerMonitor()`, after `workspaceSettleDelay`: `hoverEnterDelay: Duration = .milliseconds(250), hoverExitDelay: Duration = .milliseconds(500)`; assign them.
- `isBusy` also counts `hoverTask != nil || peekTask != nil`.
- `show(_:)`:

```swift
    func show(_ state: LimitsViewState) {
        model.state = state
        updatePointerMonitor()
        requestReconcile()
    }
```

- Replace `hoverChanged`:

```swift
    /// Waits `hoverEnterDelay` before expanding and `hoverExitDelay` before collapsing, so a pointer passing by
    /// or slipping off the edge changes nothing (spec §4).
    private func hoverChanged(_ hovering: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        guard hovering != isHovering else { return }
        hoverTask = Task {
            try? await Task.sleep(for: hovering ? hoverEnterDelay : hoverExitDelay)
            guard !Task.isCancelled else { return }
            hoverTask = nil
            isHovering = hovering
            schedulePeek()
            requestReconcile()
        }
    }

    private func updatePointerMonitor() {
        let wanted = model.state.isPeekable || isPeeking
        if wanted, !isPointerRunning {
            isPointerRunning = true
            pointer.start { [weak self] point in self?.pointerMoved(to: point) }
        } else if !wanted, isPointerRunning {
            isPointerRunning = false
            isPointerInZone = false
            pointer.stop()
        }
    }

    private func pointerMoved(to point: CGPoint) {
        guard let target = screen() else { return }
        let inside = NotchPeekZone.rect(for: target).contains(point)
        guard inside != isPointerInZone else { return }
        isPointerInZone = inside
        schedulePeek()
    }

    /// A peek starts after the pointer rests in the zone and ends after it has left both the zone and the notch.
    private func schedulePeek() {
        let wanted = isPointerInZone || (isPeeking && isHovering)
        peekTask?.cancel()
        peekTask = nil
        guard wanted != isPeeking else { return }
        peekTask = Task {
            try? await Task.sleep(for: wanted ? hoverEnterDelay : hoverExitDelay)
            guard !Task.isCancelled else { return }
            peekTask = nil
            isPeeking = wanted
            onPeekChange?(wanted)
            updatePointerMonitor()
        }
    }
```

Alerts are untouched: `present(_:)` sets `isShowingAlert` and reconciles at once, and `target(…)` already puts the alert before hover.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command.
Expected: `** TEST SUCCEEDED **`, including the existing hover tests (`quickHoverEndsCompactWithoutOverlappingCalls`, `fullScreenHidesEvenWhileHovering`), now with the injected delays.

- [ ] **Step 5: Full suite**

Run: the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`.

### Task 4: Documentation

**Files:**
- Modify: `README.md`, `docs/testing.md`, `specs/2026-10-13-notch-hover-and-when-active-design.md` (status)

- [ ] **Step 1: README**

In the Claude Code section, replace the description of "Only near limits" (search for `near limits`) with:

```
- **Show:** "Always", or "When active": the notch appears while a session works or waits for you and while a limit is near, stays a minute after work ends, and shows when you point at its place. Hovering waits a moment before expanding and before collapsing, so passing the pointer by does not open it.
```

- [ ] **Step 2: Manual checklist**

`docs/testing.md`, after the last row of the Virtual Notch Checklist:

```
| V7 | Hover delays | Move the pointer quickly across the notch (on the virtual notch, along the menu bar); rest on its edge and wiggle. | Passing by does not expand it; resting expands it after a moment; a brief slip off the edge does not collapse it. |
| V8 | When active | Settings → Show → When active. Let a session finish; wait a minute; then point at the notch's place. | The notch stays about a minute after the session finishes, then hides; pointing at its place shows it, leaving hides it again. |
```

- [ ] **Step 3: Spec status and full suite**

Set the spec's **Status** to `Implemented`. Run the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Hand over**

Ask the user to `make install` and run V7 and V8. No commit until they say "коммить".
