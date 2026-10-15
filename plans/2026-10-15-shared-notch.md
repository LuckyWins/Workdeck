# Shared Notch Implementation Plan (Codex support, plan 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the notch a shared part of the app that any agent tool feeds, with Claude Code as its first source, and move the settings that apply to every agent into a new Notch section — without changing anything a person sees except where those settings live.

**Architecture:** The shared notch files move to `Workdeck/Features/Notch/`. A new `NotchComposer` owns `NotchPresenter`, visibility (mode, peek, linger), the compact account, alerts and the menu bar text; each agent tool conforms to `AgentSource` and hands it an `AgentNotchPart` (its limit blocks, sessions and flags). `NotchSettings` holds the shared settings over the existing `UserDefaults` keys; `ClaudeCodeSettings` forwards to it so Claude's code and tests keep compiling.

**Tech Stack:** Swift 6 (MainActor default isolation), SwiftUI, Observation, Swift Testing.

**Spec:** `specs/2026-10-15-codex-support-design.md` (§3.4 Notch settings, §4 Architecture). Plans 2 (Codex limits) and 3 (Codex sessions) follow.

## Global Constraints

- Nothing visible changes in this plan except the Settings layout of §3.4: the notch, popover and alerts look and behave exactly as before. The full existing suite is the gate for every task.
- `UserDefaults` keys stay as they are, so every choice carries over (spec §3.4).
- English only in UI strings, comments and docs. Conventional Commits, no `Co-Authored-By`, no mention of AI tools. Commit only when the user says so: commit steps run at the end, after the user's check.
- Do not edit `project.pbxproj` to add or move source files (synchronized folders). `git mv` keeps history.
- Pure value types are `nonisolated`. No new dependencies.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; a single suite adds `-only-testing:WorkdeckTests/<Suite>` after `test`.

## Review Focus

1. A disabled agent next to an enabled one must contribute nothing (no blocks, no sessions, no compact account). Pinned in Task 3 (`aDisabledSourceAddsNothing`).
2. The Settings move must keep every saved choice: thresholds, mode, notchless display, forecast, alerts, keep-awake. Pinned in Task 2 (`savedChoicesCarryOver`).
3. "When active" linger and peek must keep working after the move to the composer, including during the demo. Covered by the existing `ClaudeCodeControllerTests` and `ClaudeCodeDemoControllerTests`, which must stay green unchanged.
4. A session click must reach only the source that knows the session; a source that does not know the ID ignores it. Pinned in Task 3 (`aSessionClickReachesEverySource`) and by `ClaudeSessionsController.activateSession`'s guard.
5. Keep-awake and alert toggles moved to the Notch section must still take effect at once (refresh and keep-awake update). Manual row N1 in `docs/testing.md`.

---

### Task 1: Move the shared notch files

**Files:**
- Move (`git mv`) from `Workdeck/Features/ClaudeCode/` to `Workdeck/Features/Notch/`: `NotchPresenter.swift`, `FullScreenDetector.swift`, `NotchFlash.swift`, `NotchPeek.swift`, `NotchCountdown.swift`, `TerminalStyle.swift`, `LimitsPresentation.swift`, `LimitsNotchViews.swift`, and `Sessions/SessionsNotchViews.swift`.
- Move (`git mv`) from `WorkdeckTests/ClaudeCode/` to `WorkdeckTests/Notch/`: `NotchPresenterTests.swift`, `FullScreenDetectorTests.swift`, `NotchFlashTests.swift`, `NotchPeekTests.swift`, `NotchCountdownTests.swift`, `TerminalStyleTests.swift`, `TickerShimmerTests.swift`, `LimitsPresentationTests.swift`, `UsageRingTests.swift`.

**Interfaces:** none change; types keep their names and module.

- [ ] **Step 1: Move**

```bash
cd /Users/andreu/Development/xcodeProjects/Workdeck
mkdir -p Workdeck/Features/Notch WorkdeckTests/Notch
for f in NotchPresenter FullScreenDetector NotchFlash NotchPeek NotchCountdown TerminalStyle LimitsPresentation LimitsNotchViews; do
  git mv Workdeck/Features/ClaudeCode/$f.swift Workdeck/Features/Notch/$f.swift
done
git mv Workdeck/Features/ClaudeCode/Sessions/SessionsNotchViews.swift Workdeck/Features/Notch/SessionsNotchViews.swift
for f in NotchPresenterTests FullScreenDetectorTests NotchFlashTests NotchPeekTests NotchCountdownTests TerminalStyleTests TickerShimmerTests LimitsPresentationTests UsageRingTests; do
  git mv WorkdeckTests/ClaudeCode/$f.swift WorkdeckTests/Notch/$f.swift
done
```

- [ ] **Step 2: Run the whole suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **` with the same test count as before the move (882).

- [ ] **Step 3: Update `CLAUDE.md` Architecture.** In the `Workdeck/Features/ClaudeCode/` bullet replace "shared notch views, presenter and settings live at the folder root" with "settings live at the folder root", and add after it:

```markdown
- `Workdeck/Features/Notch/` — the notch every agent tool shares: `NotchPresenter` (DynamicNotchKit), the notch views, `LimitsPresentation`, flashes, peek and countdown. Without a display that has a camera housing, `NotchPresenter` draws a virtual notch on the main display (DynamicNotchKit's `.notch` style on a plain screen) unless the "Without a notch" setting picks the menu bar text.
```

and remove that "Without a display…" sentence from the ClaudeCode bullet.

---

### Task 2: `NotchSettings`

**Files:**
- Create: `Workdeck/Features/Notch/NotchSettings.swift`
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeSettings.swift`
- Test: `WorkdeckTests/Notch/NotchSettingsTests.swift`

**Interfaces:**
- Produces: `@Observable final class NotchSettings` with `init(defaults: UserDefaults = .standard)`; properties `mode: LimitsDisplayMode`, `firstThreshold: Int`, `secondThreshold: Int`, `notifyOnReset: Bool`, `showForecast: Bool`, `collapsesOtherAccounts: Bool`, `notchlessDisplay: NotchlessDisplay`, `keepAwakeWhileWorking: Bool`, `notifyWhenFinished: Bool`, `finishedAfterMinutes: Int`, `notifyWhenNeedsYou: Bool`, `thresholds: [Int]`; statics `firstThresholdOptions`, `finishedAfterOptions`, `secondThresholdOptions(above:)`, `normalizedFirst(_:)`, `normalizedSecond(_:above:)`.
- Produces: `ClaudeCodeSettings.init(defaults: UserDefaults = .standard, notch: NotchSettings? = nil)` and `let notch: NotchSettings`; the moved properties stay on `ClaudeCodeSettings` as forwarding get/set properties, the statics as forwarding statics.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

struct NotchSettingsTests {
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!

    @Test func defaultsMatchTheOldClaudeDefaults() {
        let settings = NotchSettings(defaults: defaults)
        #expect(settings.mode == .always)
        #expect(settings.thresholds == [80, 95])
        #expect(settings.notifyOnReset)
        #expect(settings.showForecast)
        #expect(!settings.collapsesOtherAccounts)
        #expect(settings.notchlessDisplay == .virtualNotch)
        #expect(!settings.keepAwakeWhileWorking)
        #expect(!settings.notifyWhenFinished)
        #expect(settings.finishedAfterMinutes == 10)
        #expect(!settings.notifyWhenNeedsYou)
    }

    @Test func savedChoicesCarryOver() {
        defaults.set("nearLimits", forKey: "claudeLimits.mode")
        defaults.set(70, forKey: "claudeLimits.firstThreshold")
        defaults.set(90, forKey: "claudeLimits.secondThreshold")
        defaults.set(false, forKey: "claudeLimits.notifyOnReset")
        defaults.set(false, forKey: "claudeLimits.showForecast")
        defaults.set(true, forKey: "claudeLimits.collapsesOtherAccounts")
        defaults.set("menuBarText", forKey: "claudeLimits.notchlessDisplay")
        defaults.set(true, forKey: "claudeSessions.keepAwake")
        defaults.set(true, forKey: "claudeSessions.notifyFinished")
        defaults.set(15, forKey: "claudeSessions.finishedAfterMinutes")
        defaults.set(true, forKey: "claudeSessions.notifyNeedsYou")
        let settings = NotchSettings(defaults: defaults)
        #expect(settings.mode == .whenActive)
        #expect(settings.thresholds == [70, 90])
        #expect(!settings.notifyOnReset)
        #expect(!settings.showForecast)
        #expect(settings.collapsesOtherAccounts)
        #expect(settings.notchlessDisplay == .menuBarText)
        #expect(settings.keepAwakeWhileWorking)
        #expect(settings.notifyWhenFinished)
        #expect(settings.finishedAfterMinutes == 15)
        #expect(settings.notifyWhenNeedsYou)
    }

    @Test func claudeSettingsShareTheNotchSettings() {
        let notch = NotchSettings(defaults: defaults)
        let claude = ClaudeCodeSettings(defaults: defaults, notch: notch)
        claude.firstThreshold = 60
        #expect(notch.firstThreshold == 60)
        notch.mode = .whenActive
        #expect(claude.mode == .whenActive)
        #expect(NotchSettings(defaults: defaults).firstThreshold == 60)
    }

    @Test func thresholdsStayNormalized() {
        let settings = NotchSettings(defaults: defaults)
        settings.firstThreshold = 97
        #expect(settings.firstThreshold == 95)
        #expect(settings.secondThreshold == 100)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchSettingsTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `cannot find 'NotchSettings' in scope`.

- [ ] **Step 3: Create `NotchSettings`**

```swift
import Foundation
import Observation

/// Settings for every agent that shows in the notch (Codex spec §3.4). The keys are the ones Claude Code's settings
/// used, so saved choices carry over.
@Observable
final class NotchSettings {
    static let firstThresholdOptions = Array(stride(from: 50, through: 95, by: 5))
    static let finishedAfterOptions = [1, 2, 5, 10, 15, 30]

    static func secondThresholdOptions(above first: Int) -> [Int] {
        Array(stride(from: first + 5, through: 100, by: 5))
    }

    private enum Keys {
        static let mode = "claudeLimits.mode"
        static let firstThreshold = "claudeLimits.firstThreshold"
        static let secondThreshold = "claudeLimits.secondThreshold"
        static let notifyOnReset = "claudeLimits.notifyOnReset"
        static let showForecast = "claudeLimits.showForecast"
        static let collapsesOtherAccounts = "claudeLimits.collapsesOtherAccounts"
        static let notchlessDisplay = "claudeLimits.notchlessDisplay"
        static let keepAwake = "claudeSessions.keepAwake"
        static let notifyFinished = "claudeSessions.notifyFinished"
        static let finishedAfterMinutes = "claudeSessions.finishedAfterMinutes"
        static let notifyNeedsYou = "claudeSessions.notifyNeedsYou"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var mode: LimitsDisplayMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }

    var firstThreshold: Int {
        didSet {
            let normalized = Self.normalizedFirst(firstThreshold)
            if normalized != firstThreshold {
                firstThreshold = normalized
            }
            defaults.set(firstThreshold, forKey: Keys.firstThreshold)
            if secondThreshold <= firstThreshold {
                secondThreshold = Self.normalizedSecond(secondThreshold, above: firstThreshold)
            }
        }
    }

    var secondThreshold: Int {
        didSet {
            let normalized = Self.normalizedSecond(secondThreshold, above: firstThreshold)
            if normalized != secondThreshold {
                secondThreshold = normalized
            }
            defaults.set(secondThreshold, forKey: Keys.secondThreshold)
        }
    }

    var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: Keys.notifyOnReset) }
    }

    /// Show when a limit will run out at the current pace (expanded notch).
    var showForecast: Bool {
        didSet { defaults.set(showForecast, forKey: Keys.showForecast) }
    }

    /// The expanded notch shows every account's limits as one line (the short view).
    var collapsesOtherAccounts: Bool {
        didSet { defaults.set(collapsesOtherAccounts, forKey: Keys.collapsesOtherAccounts) }
    }

    /// What shows the indicator on a display without a camera housing.
    var notchlessDisplay: NotchlessDisplay {
        didSet { defaults.set(notchlessDisplay.rawValue, forKey: Keys.notchlessDisplay) }
    }

    /// Hold a power assertion while any agent's session works.
    var keepAwakeWhileWorking: Bool {
        didSet { defaults.set(keepAwakeWhileWorking, forKey: Keys.keepAwake) }
    }

    var notifyWhenFinished: Bool {
        didSet { defaults.set(notifyWhenFinished, forKey: Keys.notifyFinished) }
    }

    /// Only turns at least this long announce that they finished.
    var finishedAfterMinutes: Int {
        didSet { defaults.set(finishedAfterMinutes, forKey: Keys.finishedAfterMinutes) }
    }

    var notifyWhenNeedsYou: Bool {
        didSet { defaults.set(notifyWhenNeedsYou, forKey: Keys.notifyNeedsYou) }
    }

    var thresholds: [Int] {
        [firstThreshold, secondThreshold]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Keys.mode).flatMap(LimitsDisplayMode.init(rawValue:)) ?? .always
        let first = Self.normalizedFirst(defaults.object(forKey: Keys.firstThreshold) as? Int ?? 80)
        firstThreshold = first
        secondThreshold = Self.normalizedSecond(defaults.object(forKey: Keys.secondThreshold) as? Int ?? 95, above: first)
        notifyOnReset = defaults.object(forKey: Keys.notifyOnReset) as? Bool ?? true
        showForecast = defaults.object(forKey: Keys.showForecast) as? Bool ?? true
        collapsesOtherAccounts = defaults.bool(forKey: Keys.collapsesOtherAccounts)
        notchlessDisplay = defaults.string(forKey: Keys.notchlessDisplay).flatMap(NotchlessDisplay.init(rawValue:)) ?? .virtualNotch
        keepAwakeWhileWorking = defaults.bool(forKey: Keys.keepAwake)
        notifyWhenFinished = defaults.bool(forKey: Keys.notifyFinished)
        let minutes = defaults.object(forKey: Keys.finishedAfterMinutes) as? Int ?? 10
        finishedAfterMinutes = Self.finishedAfterOptions.contains(minutes) ? minutes : 10
        notifyWhenNeedsYou = defaults.bool(forKey: Keys.notifyNeedsYou)
    }

    /// 50–95 in steps of 5.
    static func normalizedFirst(_ value: Int) -> Int {
        roundedToStep(min(max(value, 50), 95))
    }

    /// Above `first`, up to 100, in steps of 5.
    static func normalizedSecond(_ value: Int, above first: Int) -> Int {
        roundedToStep(min(max(value, first + 5), 100))
    }

    private static func roundedToStep(_ value: Int) -> Int {
        Int((Double(value) / 5).rounded()) * 5
    }
}
```

- [ ] **Step 4: Slim `ClaudeCodeSettings` to forward**

In `ClaudeCodeSettings.swift`:
- Replace the statics `firstThresholdOptions`, `finishedAfterOptions`, `secondThresholdOptions(above:)` and the static `normalizedFirst`, `normalizedSecond`, `roundedToStep` with forwarding statics:

```swift
    static let firstThresholdOptions = NotchSettings.firstThresholdOptions
    static let finishedAfterOptions = NotchSettings.finishedAfterOptions

    static func secondThresholdOptions(above first: Int) -> [Int] {
        NotchSettings.secondThresholdOptions(above: first)
    }

    static func normalizedFirst(_ value: Int) -> Int {
        NotchSettings.normalizedFirst(value)
    }

    static func normalizedSecond(_ value: Int, above first: Int) -> Int {
        NotchSettings.normalizedSecond(value, above: first)
    }
```

- Remove from `Keys`: `mode`, `firstThreshold`, `secondThreshold`, `notifyOnReset`, `showForecast`, `collapsesOtherAccounts`, `notchlessDisplay`, `keepAwake`, `notifyFinished`, `finishedAfterMinutes`, `notifyNeedsYou`.
- Remove the stored properties `mode`, `firstThreshold`, `secondThreshold`, `notifyOnReset`, `showForecast`, `collapsesOtherAccounts`, `notchlessDisplay`, `keepAwakeWhileWorking`, `notifyWhenFinished`, `finishedAfterMinutes`, `notifyWhenNeedsYou`, `thresholds`, and their lines in `init`.
- Add, after `@ObservationIgnored private let defaults: UserDefaults`:

```swift
    /// The settings every agent shares; Claude's code reads them through the forwarding properties below.
    @ObservationIgnored let notch: NotchSettings

    var mode: LimitsDisplayMode {
        get { notch.mode }
        set { notch.mode = newValue }
    }

    var firstThreshold: Int {
        get { notch.firstThreshold }
        set { notch.firstThreshold = newValue }
    }

    var secondThreshold: Int {
        get { notch.secondThreshold }
        set { notch.secondThreshold = newValue }
    }

    var notifyOnReset: Bool {
        get { notch.notifyOnReset }
        set { notch.notifyOnReset = newValue }
    }

    var showForecast: Bool {
        get { notch.showForecast }
        set { notch.showForecast = newValue }
    }

    var collapsesOtherAccounts: Bool {
        get { notch.collapsesOtherAccounts }
        set { notch.collapsesOtherAccounts = newValue }
    }

    var notchlessDisplay: NotchlessDisplay {
        get { notch.notchlessDisplay }
        set { notch.notchlessDisplay = newValue }
    }

    var keepAwakeWhileWorking: Bool {
        get { notch.keepAwakeWhileWorking }
        set { notch.keepAwakeWhileWorking = newValue }
    }

    var notifyWhenFinished: Bool {
        get { notch.notifyWhenFinished }
        set { notch.notifyWhenFinished = newValue }
    }

    var finishedAfterMinutes: Int {
        get { notch.finishedAfterMinutes }
        set { notch.finishedAfterMinutes = newValue }
    }

    var notifyWhenNeedsYou: Bool {
        get { notch.notifyWhenNeedsYou }
        set { notch.notifyWhenNeedsYou = newValue }
    }

    var thresholds: [Int] {
        notch.thresholds
    }
```

- Change the initializer's signature and first lines to:

```swift
    init(defaults: UserDefaults = .standard, notch: NotchSettings? = nil) {
        self.defaults = defaults
        self.notch = notch ?? NotchSettings(defaults: defaults)
```

- [ ] **Step 5: Run the new tests and the settings suites**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchSettingsTests -only-testing:WorkdeckTests/ClaudeCodeSettingsTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Run the whole suite**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`.

---

### Task 3: `AgentSource`, `AgentNotchPart` and `NotchComposer`

**Files:**
- Create: `Workdeck/Features/Notch/AgentSource.swift`, `Workdeck/Features/Notch/NotchComposer.swift`
- Test: `WorkdeckTests/Notch/NotchComposerTests.swift`

**Interfaces:**
- Consumes: `NotchSettings` (Task 2); `LimitsPresenting`, `LimitsViewState`, `AccountLimitsViewState`, `LimitsPresentation`, `SessionsPresentation`, `SessionsViewState`, `UsageFormatting`, `NotchPresenter.targetIndex` (existing).
- Produces:
  - `nonisolated enum AgentKind: String, CaseIterable, Sendable { case claudeCode, codex }` with `mark` and `name`.
  - `nonisolated struct AgentNotchPart: Equatable, Sendable` with the fields below.
  - `protocol AgentSource: AnyObject` with `notchPart`, `activateSession(id:)`, `activateProject(named:)`, `refreshNow()`, `openChats(account:)`, `dismissRecap()`, `openRecapDetails()` (the last three default to doing nothing).
  - `@Observable final class NotchComposer` with `init(settings:presenter:cameraHousings:clock:linger:)`, `let settings: NotchSettings`, `let presenter: any LimitsPresenting`, `private(set) var state: LimitsViewState`, `register(_:)`, `start()`, `refresh(alerts:)`, `noteAlerts()`, `flash(_:)`, `hasNotchScreen`, `menuBarText`, `menuBarLevel`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeAgentSource: AgentSource {
    var notchPart: AgentNotchPart
    private(set) var activated: [String] = []
    private(set) var projects: [String] = []
    private(set) var refreshes = 0

    init(_ part: AgentNotchPart) {
        notchPart = part
    }

    func activateSession(id: String) { activated.append(id) }
    func activateProject(named name: String) { projects.append(name) }
    func refreshNow() { refreshes += 1 }
}

@MainActor
struct NotchComposerTests {
    let presenter = FakePresenter()
    let settings = NotchSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)

    private func makeComposer() -> NotchComposer {
        NotchComposer(settings: settings, presenter: presenter, cameraHousings: { [true] }, clock: { fixedNow })
    }

    private func part(_ agent: AgentKind, enabled: Bool = true, percent: Double = 40, account: String = "main", sessions: [ClaudeSession] = []) -> AgentNotchPart {
        AgentNotchPart(
            agent: agent,
            isEnabled: enabled,
            hasSource: true,
            showsLimits: true,
            accounts: [AccountLimitsViewState(name: account, windows: [window(.fiveHour, percent)], age: 60)],
            compactIndex: 0,
            compactLabel: nil,
            now: fixedNow,
            sessions: sessions,
            sessionsNow: fixedNow,
            showsAccounts: false,
            sessionsConnected: true,
            activeCount: sessions.filter { $0.status != .idle }.count
        )
    }

    private func session(_ id: String, at seconds: TimeInterval) -> ClaudeSession {
        ClaudeSession(id: id, cwd: "/p/\(id)", status: .working, since: fixedNow, lastEventAt: fixedNow.addingTimeInterval(seconds))
    }

    @Test func oneSourceShowsItsLimitsAndSessions() throws {
        let composer = makeComposer()
        composer.register(FakeAgentSource(part(.claudeCode, sessions: [session("a", at: 0)])))
        composer.refresh()
        let shown = try #require(presenter.shown.last)
        #expect(shown.display == .notch(.normal))
        #expect(shown.accounts.map(\.name) == ["main"])
        #expect(shown.sessions.rows.map(\.id) == ["a"])
        #expect(shown.windows.first?.usedPercent == 40)
    }

    @Test func noEnabledSourceHidesTheNotch() {
        let composer = makeComposer()
        composer.register(FakeAgentSource(part(.claudeCode, enabled: false)))
        composer.refresh()
        #expect(composer.state.display == .hidden)
    }

    @Test func twoSourcesMergeInRegistrationOrder() throws {
        let composer = makeComposer()
        composer.register(FakeAgentSource(part(.claudeCode, sessions: [session("a", at: 0)])))
        composer.register(FakeAgentSource(part(.codex, percent: 10, account: "codex", sessions: [session("b", at: 5)])))
        composer.refresh()
        let shown = try #require(presenter.shown.last)
        #expect(shown.accounts.map(\.name) == ["main", "codex"])
        #expect(Set(shown.sessions.rows.map(\.id)) == ["a", "b"])
        // The compact notch follows the latest session: b (Codex) at 10 %.
        #expect(shown.windows.first?.usedPercent == 10)
    }

    @Test func aDisabledSourceAddsNothing() throws {
        let composer = makeComposer()
        composer.register(FakeAgentSource(part(.claudeCode, sessions: [session("a", at: 0)])))
        composer.register(FakeAgentSource(part(.codex, enabled: false, percent: 10, account: "codex", sessions: [session("b", at: 5)])))
        composer.refresh()
        let shown = try #require(presenter.shown.last)
        #expect(shown.accounts.map(\.name) == ["main"])
        #expect(shown.sessions.rows.map(\.id) == ["a"])
        #expect(shown.windows.first?.usedPercent == 40)
    }

    @Test func aSessionClickReachesEverySource() {
        let composer = makeComposer()
        let first = FakeAgentSource(part(.claudeCode))
        let second = FakeAgentSource(part(.codex, account: "codex"))
        composer.register(first)
        composer.register(second)
        composer.start()
        presenter.sessionAction?("s1")
        presenter.refreshAction?()
        #expect(first.activated == ["s1"])
        #expect(second.activated == ["s1"])
        #expect(first.refreshes == 1)
        #expect(second.refreshes == 1)
    }

    @Test func aPartThatKeepsVisibleHoldsAWhenActiveNotch() {
        settings.mode = .whenActive
        let composer = makeComposer()
        let source = FakeAgentSource(part(.claudeCode))
        composer.register(source)
        composer.refresh()
        #expect(composer.state.display == .hidden)
        source.notchPart.keepsVisible = true
        composer.refresh()
        #expect(composer.state.display == .notch(.normal))
    }

    @Test func theDemoShowsTheNotchWhateverTheMode() {
        settings.mode = .whenActive
        let composer = makeComposer()
        var demo = part(.claudeCode, enabled: false)
        demo.isDemo = true
        composer.register(FakeAgentSource(demo))
        composer.refresh()
        #expect(composer.state.display == .notch(.normal))
        #expect(!composer.state.isPeekable)
    }

    @Test func alertsFlashAfterTheNotchShows() {
        let composer = makeComposer()
        composer.register(FakeAgentSource(part(.claudeCode)))
        composer.refresh(alerts: [.sessionNeedsYou(project: "a")])
        #expect(presenter.shown.count == 1)
        #expect(presenter.flashes == [[.sessionNeedsYou(project: "a")]])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchComposerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `cannot find type 'AgentSource' in scope`.

- [ ] **Step 3: Create `AgentSource.swift`**

```swift
import Foundation

/// The agent tools that show in the notch (Codex spec §3.1).
nonisolated enum AgentKind: String, CaseIterable, Sendable {
    case claudeCode
    case codex

    /// Starts every block, session row and alert while more than one agent is on.
    var mark: String {
        switch self {
        case .claudeCode: "✳"
        case .codex: "◎"
        }
    }

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// What one agent tool shows in the notch right now (Codex spec §4).
nonisolated struct AgentNotchPart: Equatable, Sendable {
    var agent: AgentKind
    /// The tool's popover switch.
    var isEnabled: Bool
    /// Limits or sessions are connected: "When active" may peek at a hidden notch.
    var hasSource: Bool
    /// A limits source is on.
    var showsLimits: Bool
    /// Limit blocks in their fixed order; never empty.
    var accounts: [AccountLimitsViewState]
    /// The block the compact notch shows when this agent has the compact notch.
    var compactIndex: Int
    /// The letter before the compact percent; `nil` for the main account.
    var compactLabel: String?
    /// When the compact block's figures were read.
    var now: Date
    /// Listed sessions in display order.
    var sessions: [ClaudeSession]
    var sessionsNow: Date
    /// Session rows carry their account tag.
    var showsAccounts: Bool
    /// Session hooks are connected; without them there is no sessions list at all.
    var sessionsConnected: Bool
    /// Real sessions at work, for "When active" (the demo shows its own but keeps timing real work).
    var activeCount: Int
    /// Something of this agent keeps the notch up, e.g. a pending recap.
    var keepsVisible = false
    /// The demo plays: the notch shows whatever the mode.
    var isDemo = false

    var compactBlock: AccountLimitsViewState {
        accounts[min(max(compactIndex, 0), accounts.count - 1)]
    }

    /// The latest session event, which decides the compact notch across agents.
    var lastSessionEvent: Date? {
        sessions.map(\.lastEventAt).max()
    }
}

/// An agent tool that feeds the notch (Codex spec §4).
protocol AgentSource: AnyObject {
    var notchPart: AgentNotchPart { get }
    /// A session row was clicked; a source that does not know the ID ignores it.
    func activateSession(id: String)
    /// A session alert was clicked; it knows only the project's name.
    func activateProject(named name: String)
    /// The refresh button in the expanded notch.
    func refreshNow()
    /// A limit alert was clicked, by account label.
    func openChats(account: String)
    func dismissRecap()
    func openRecapDetails()
}

extension AgentSource {
    func openChats(account: String) {}
    func dismissRecap() {}
    func openRecapDetails() {}
}
```

- [ ] **Step 4: Create `NotchComposer.swift`**

```swift
import AppKit
import OSLog
import Observation

/// Owns the notch: merges what every agent tool shows, decides whether the notch shows, and hands alerts to the
/// presenter (Codex spec §4). Moved here from `ClaudeCodeController.refresh()`.
@Observable
final class NotchComposer {
    let settings: NotchSettings
    private(set) var state = LimitsViewState.hidden

    @ObservationIgnored let presenter: any LimitsPresenting
    @ObservationIgnored private var sources: [any AgentSource] = []
    /// Whether each connected display has a camera housing; with the setting it decides between a real or virtual
    /// notch and the menu bar text.
    @ObservationIgnored private let cameraHousings: @MainActor () -> [Bool]
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let linger: TimeInterval
    /// When the last active session went idle; "When active" keeps the notch `linger` seconds after it.
    @ObservationIgnored private var workEndedAt: Date?
    @ObservationIgnored private var wasActive = false
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var isPeeking = false
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isStarted = false

    init(
        settings: NotchSettings,
        presenter: any LimitsPresenting,
        cameraHousings: @escaping @MainActor () -> [Bool] = { NSScreen.screens.map { $0.safeAreaInsets.top > 0 } },
        clock: @escaping () -> Date = { Date() },
        linger: TimeInterval = 60
    ) {
        self.settings = settings
        self.presenter = presenter
        self.cameraHousings = cameraHousings
        self.clock = clock
        self.linger = linger
    }

    func register(_ source: any AgentSource) {
        sources.append(source)
    }

    /// A display shows the notch: a camera housing, or the virtual notch.
    var hasNotchScreen: Bool {
        NotchPresenter.targetIndex(cameraHousings: cameraHousings(), notchless: settings.notchlessDisplay) != nil
    }

    /// Text next to the Workdeck icon when no notch screen is available.
    var menuBarText: String? {
        if case let .menuBar(text, _) = state.display { text } else { nil }
    }

    var menuBarLevel: LimitsLevel {
        if case let .menuBar(_, level) = state.display { level } else { .noData }
    }

    /// Wires the presenter's actions to the sources; safe to call from every source's `start()`.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        presenter.setSessionAction { [weak self] id in
            self?.sources.forEach { $0.activateSession(id: id) }
        }
        presenter.setProjectAction { [weak self] name in
            self?.sources.forEach { $0.activateProject(named: name) }
        }
        presenter.setRefreshAction { [weak self] in
            self?.sources.forEach { $0.refreshNow() }
        }
        presenter.setToggleAccountsAction { [weak self] in
            guard let self else { return }
            settings.collapsesOtherAccounts.toggle()
            refresh()
        }
        presenter.setPeekAction { [weak self] peeking in
            guard let self else { return }
            isPeeking = peeking
            refresh()
        }
        presenter.setChatsAction { [weak self] account in
            self?.sources.forEach { $0.openChats(account: account) }
        }
        presenter.setRecapDismissAction { [weak self] in
            self?.sources.forEach { $0.dismissRecap() }
        }
        presenter.setRecapDetailsAction { [weak self] in
            self?.sources.forEach { $0.openRecapDetails() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// An alert restarts the "When active" linger, as if work had just ended (flash spec §2.3).
    func noteAlerts() {
        workEndedAt = clock()
        lingerTask?.cancel()
        lingerTask = nil
    }

    func flash(_ alerts: [LimitsAlert]) {
        guard !alerts.isEmpty else { return }
        // Session alerts are logged by their policy; the presenter decides whether anything shows.
        for alert in alerts where LimitsText.alertProject(alert) == nil {
            WorkdeckLog.alerts.notice("\(LimitsText.alertTitle(alert, showsAccount: true), privacy: .public), alert")
        }
        presenter.flash(alerts)
    }

    /// Recomposes the notch from every source; `alerts` happened just now and flash after it shows. Limit alerts come
    /// first: in "When active" an alert counts as activity, so a hidden notch shows (flash spec §2.3).
    func refresh(alerts: [LimitsAlert] = []) {
        if !alerts.isEmpty {
            noteAlerts()
        }
        let parts = sources.map(\.notchPart)
        guard !parts.isEmpty else { return }
        let enabled = parts.filter { $0.isEnabled || $0.isDemo }
        // With every agent off the notch hides; the state still describes the agents for the popover and tests.
        let shown = enabled.isEmpty ? parts : enabled
        let compact = Self.compactPart(among: shown)
        let block = compact.compactBlock
        let pressing = UsageFormatting.mostPressing(block.windows.filter { $0.resetsAt > compact.now })
        let hasData = block.age != nil
        let thresholds = settings.thresholds
        let isDemo = shown.contains(\.isDemo)
        let isActive = shown.contains { $0.activeCount > 0 }
        let isLingering = lingers(isActive: isActive)
        let isEnabled = parts.contains(\.isEnabled)
        let showsLimits = shown.contains(\.showsLimits)
        let hasNotchScreen = hasNotchScreen
        let keepsVisible = parts.contains(\.keepsVisible)
        func decide() -> LimitsDisplay {
            LimitsPresentation.display(
                isEnabled: isEnabled,
                isConnected: showsLimits,
                mode: settings.mode,
                hasNotchScreen: hasNotchScreen,
                pressing: pressing,
                hasData: hasData,
                thresholds: thresholds,
                hasSessions: isActive || (settings.mode == .whenActive && isLingering) || keepsVisible,
                isPeeking: isPeeking,
                label: compact.compactLabel
            )
        }
        var display: LimitsDisplay
        var isPeekable = false
        if isDemo {
            display = .notch(LimitsPresentation.displayLevel(pressing: pressing, hasData: true, thresholds: thresholds))
        } else {
            display = decide()
            let canPeek = settings.mode == .whenActive && isEnabled && hasNotchScreen && parts.contains(\.hasSource)
            if !canPeek {
                isPeeking = false
            }
            // A notch the pointer is on stays until the pointer leaves, even when its reason to show ends (spec §7).
            if canPeek, display == .hidden, !isPeeking, presenter.isPointerOnNotch() {
                isPeeking = true
                display = decide()
            }
            isPeekable = canPeek && display == .hidden
        }
        let sessionParts = shown.filter(\.sessionsConnected)
        let sessions = sessionParts.isEmpty
            ? SessionsViewState.none
            : SessionsPresentation.viewState(
                sessions: Self.merged(sessionParts.map(\.sessions)),
                now: sessionParts.map(\.sessionsNow).max() ?? clock(),
                showsAccounts: sessionParts.contains(\.showsAccounts)
            )
        state = LimitsViewState(
            display: display,
            windows: block.windows,
            now: compact.now,
            age: block.age,
            thresholds: thresholds,
            forecasts: block.forecasts,
            refresh: block.refresh,
            showsLimits: showsLimits,
            isPeekable: isPeekable,
            isPeeking: isDemo ? false : isPeeking,
            sessions: sessions,
            accounts: shown.flatMap(\.accounts),
            compactLabel: compact.compactLabel,
            collapsesOtherAccounts: settings.collapsesOtherAccounts
        )
        presenter.show(state)
        flash(alerts)
    }

    /// The agent whose session had the latest event; without sessions, the first agent (Codex spec §3.1).
    static func compactPart(among parts: [AgentNotchPart]) -> AgentNotchPart {
        let withSessions = parts.filter { $0.lastSessionEvent != nil }
        return withSessions.max { ($0.lastSessionEvent ?? .distantPast) < ($1.lastSessionEvent ?? .distantPast) } ?? parts[0]
    }

    /// One agent's list keeps its order; several are merged in the order one store keeps (waiting, working, idle;
    /// newest first).
    static func merged(_ lists: [[ClaudeSession]]) -> [ClaudeSession] {
        guard lists.count > 1 else { return lists.first ?? [] }
        return lists.flatMap { $0 }.sorted(by: ClaudeSessionStore.displayOrder)
    }

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
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchComposerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`.

---

### Task 4: Claude Code feeds the composer

**Files:**
- Modify: `Workdeck/Features/ClaudeCode/ClaudeCodeController.swift`
- Modify: `Workdeck/Features/ClaudeCode/Sessions/ClaudeSessionsController.swift` (expose the listed sessions)
- Test: the existing suites, unchanged: `ClaudeCodeControllerTests`, `RecapControllerTests`, `AccountsCompositionTests`, `ClaudeCodeDemoControllerTests`; plus one new test in `WorkdeckTests/Notch/NotchComposerTests.swift`.

**Interfaces:**
- Consumes: Task 3's `NotchComposer`, `AgentSource`, `AgentNotchPart`, `AgentKind`.
- Produces: `ClaudeCodeController: AgentSource`; `init(settings:limits:sessions:composer:clock:recapStore:calendar:)` (the app's) and the existing `init(settings:limits:sessions:presenter:cameraHousings:clock:linger:recapStore:calendar:)` kept as a convenience initializer that builds its own composer (tests); `let composer: NotchComposer`; `state`, `menuBarText`, `menuBarLevel` forward to the composer; `notchSettingsChanged()`.
- Produces: `ClaudeSessionsController.listedSessions: [ClaudeSession]` and `showsAccounts: Bool`.

- [ ] **Step 1: Write the failing test** (append to `NotchComposerTests`)

```swift
    @Test func claudeCodeIsASource() {
        let settings = ClaudeCodeSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)
        let directory = makeTemporaryDirectory()
        let limits = ClaudeLimitsController(
            settings: settings,
            store: ClaudeUsageStore(fileURL: directory.appending(path: "claude-usage.json")) { fixedNow },
            connector: FakeConnector(),
            poller: FakePoller(),
            activity: FakeActivity()
        )
        let sessions = ClaudeSessionsController(
            settings: settings,
            store: ClaudeSessionStore(directory: directory.appending(path: "sessions"), liveness: FakeLiveness()) { fixedNow },
            hooksConnector: FakeHooksConnector(),
            activator: FakeActivator(),
            sleepPreventer: FakeSleepPreventer(),
            frontmostBundleID: { nil }
        )
        let composer = NotchComposer(settings: settings.notch, presenter: presenter, cameraHousings: { [true] }, clock: { fixedNow })
        let controller = ClaudeCodeController(settings: settings, limits: limits, sessions: sessions, composer: composer, clock: { fixedNow })
        #expect(controller.notchPart.agent == .claudeCode)
        #expect(controller.notchPart.accounts.map(\.name) == ["main"])
        #expect(controller.composer === composer)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchComposerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error `extra argument 'composer' in call` (or `value of type 'ClaudeCodeController' has no member 'notchPart'`).

- [ ] **Step 3: Expose the listed sessions in `ClaudeSessionsController`**

Replace `viewState` with:

```swift
    /// Sessions of the main instance and of known instances; one of an instance Workdeck does not know (an old hook
    /// entry) is not shown. Empty without hooks.
    var listedSessions: [ClaudeSession] {
        guard isHooksConnected else { return [] }
        return store.sessions.filter { $0.instance.map { extraConnectors[$0] != nil } ?? true }
    }

    /// Session rows carry the account tag once there is an extra instance.
    var showsAccounts: Bool {
        !extraConnectors.isEmpty
    }

    var viewState: SessionsViewState {
        guard isHooksConnected else { return .none }
        return SessionsPresentation.viewState(sessions: listedSessions, now: store.now, showsAccounts: showsAccounts)
    }
```

- [ ] **Step 4: Rework `ClaudeCodeController`**

4a. Stored properties. Remove `state`, `presenter`, `cameraHousings`, `screenObserver`, `linger`, `workEndedAt`, `wasActive`, `lingerTask`, `isPeeking`. Add:

```swift
    /// The notch this tool feeds; the app shares it with every agent tool (Codex spec §4).
    @ObservationIgnored let composer: NotchComposer
```

4b. Initializers. Replace `init(…)` with the designated initializer and keep the old signature as a convenience initializer:

```swift
    init(
        settings: ClaudeCodeSettings,
        limits: ClaudeLimitsController,
        sessions: ClaudeSessionsController,
        composer: NotchComposer,
        clock: @escaping () -> Date = { Date() },
        recapStore: RecapStore? = nil,
        calendar: Calendar = RecapCalendar.calendar()
    ) {
        self.settings = settings
        self.limits = limits
        self.sessions = sessions
        self.composer = composer
        self.clock = clock
        self.recapStore = recapStore
        self.calendar = calendar
        statistics = StatisticsController(calendar: calendar, clock: clock)
        composer.register(self)
    }

    /// A notch of its own, fed only by Claude Code: tests and a single-agent setup.
    convenience init(
        settings: ClaudeCodeSettings,
        limits: ClaudeLimitsController,
        sessions: ClaudeSessionsController,
        presenter: any LimitsPresenting,
        cameraHousings: @escaping @MainActor () -> [Bool] = { NSScreen.screens.map { $0.safeAreaInsets.top > 0 } },
        clock: @escaping () -> Date = { Date() },
        linger: TimeInterval = 60,
        recapStore: RecapStore? = nil,
        calendar: Calendar = RecapCalendar.calendar()
    ) {
        let composer = NotchComposer(settings: settings.notch, presenter: presenter, cameraHousings: cameraHousings, clock: clock, linger: linger)
        self.init(settings: settings, limits: limits, sessions: sessions, composer: composer, clock: clock, recapStore: recapStore, calendar: calendar)
    }
```

4c. Forwarders, replacing the old `menuBarText` / `menuBarLevel`:

```swift
    var state: LimitsViewState {
        composer.state
    }

    /// Text next to the Workdeck icon when no notch screen is available.
    var menuBarText: String? {
        composer.menuBarText
    }

    var menuBarLevel: LimitsLevel {
        composer.menuBarLevel
    }

    /// A shared notch setting changed in Settings: alerts, the forecast and keep-awake follow at once.
    func notchSettingsChanged() {
        refresh()
    }
```

4d. `start()`. Remove every `presenter.set…Action` call and the screen observer; keep the rest, call `composer.start()` first, and route session alerts through the composer:

```swift
    func start() {
        composer.start()
        limits.onChange = { [weak self] in self?.refresh() }
        sessions.onChange = { [weak self] in self?.refresh() }
        sessions.onAlerts = { [weak self] alerts in
            // During the demo real alerts are dropped, not kept for later (demo mode spec §2.3).
            guard let self, !alerts.isEmpty, !isDemoActive else { return }
            composer.noteAlerts()
            refresh()
            composer.flash(alerts)
        }
        if let recapStore {
            recorder = RecapRecorder(days: recapStore.load(now: clock(), calendar: calendar), calendar: calendar)
        }
        updateStatistics()
        limits.onActivityChange = { [weak self] active in
            if active {
                self?.checkRecap()
            }
        }
        limits.start()
        sessions.start()
        checkRecap()
    }
```

4e. `refresh()` becomes Claude's own work plus the composer:

```swift
    /// Keep-awake, the recap and Statistics, then the notch with this tool's limit alerts.
    func refresh() {
        recordRecap()
        updateStatistics()
        sessions.updateKeepAwake()
        let limitAlerts = limits.takeAlerts()
        // Real limit alerts during the demo are dropped with it (demo mode spec §2.3).
        if isDemoActive {
            for alert in limitAlerts {
                WorkdeckLog.alerts.notice("\(LimitsText.alertTitle(alert, showsAccount: true), privacy: .public), alert dropped during the demo")
            }
            composer.refresh()
            return
        }
        composer.refresh(alerts: limitAlerts)
    }
```

4f. The part. Replace `showDemoFrame()` with `demoPart` and add `notchPart` (the `AgentSource` requirements go into an extension at the end of the file):

```swift
extension ClaudeCodeController: AgentSource {
    var notchPart: AgentNotchPart {
        if isDemoActive {
            return demoPart
        }
        let withData = limits.accounts.filter { $0.hasData || usageProblem(of: $0) != nil || isWaiting($0) }
        let shown = withData.isEmpty ? [limits.main] : withData
        let compact = compactAccount(among: shown)
        let plans = planLabels()
        let listed = sessions.listedSessions
        // Accounts with a listed session get full blocks; with no session anywhere, the compact notch's account does.
        let withSessions = Set(sessions.store.sessions.map { $0.instance ?? ClaudeInstance.mainName })
        let activeLabels = withSessions.isEmpty ? [compact.label] : withSessions
        return AgentNotchPart(
            agent: .claudeCode,
            isEnabled: settings.isEnabled,
            hasSource: hasAnySource,
            showsLimits: limits.hasDataSource,
            // Blocks keep the accounts' fixed order (main, then instances), so sessions on two accounts do not swap them.
            accounts: shown.map { account in
                AccountLimitsViewState(
                    name: account.label,
                    windows: account.store.allWindows,
                    age: account.store.age,
                    forecasts: limits.forecasts(for: account),
                    refresh: limits.refreshState(for: account),
                    problem: usageProblem(of: account),
                    isWaiting: isWaiting(account),
                    plan: plans[account.label],
                    isActive: activeLabels.contains(account.label)
                )
            },
            compactIndex: shown.firstIndex { $0.label == compact.label } ?? 0,
            // Main needs no letter; another account is always marked, even when it is the only one with data.
            compactLabel: compact.name.map { String($0.prefix(1)) },
            now: compact.store.now,
            sessions: listed,
            sessionsNow: sessions.store.now,
            showsAccounts: sessions.showsAccounts,
            sessionsConnected: sessions.isHooksConnected,
            activeCount: sessions.viewState.activeCount,
            keepsVisible: pendingRecap != nil
        )
    }

    func activateSession(id: String) {
        guard !isDemoActive else { return }
        sessions.activateSession(id: id)
    }

    func activateProject(named name: String) {
        guard !isDemoActive else { return }
        sessions.activateProject(named: name)
    }

    func refreshNow() {
        guard !isDemoActive else { return }
        limits.refreshNow()
    }

    func openChats(account: String) {
        guard !isDemoActive else { return }
        onOpenChats?(sessions.latestSessionID(ofAccount: account))
    }
}
```

and, in the class body, replacing `showDemoFrame()`:

```swift
    /// The notch part from the demo script, built like the real one (demo mode spec §2.3).
    private var demoPart: AgentNotchPart {
        let now = clock()
        let frame = ClaudeCodeDemoScript.frame(at: demoElapsed, now: now, thresholds: settings.thresholds)
        let withSessions = Set(frame.sessions.map { $0.instance ?? ClaudeInstance.mainName })
        return AgentNotchPart(
            agent: .claudeCode,
            isEnabled: true,
            hasSource: true,
            showsLimits: true,
            accounts: frame.accounts.map { account in
                AccountLimitsViewState(
                    name: account.name,
                    windows: account.windows,
                    age: account.age,
                    forecasts: demoForecasts(account.windows, now: now),
                    plan: account.plan,
                    isActive: withSessions.contains(account.name)
                )
            },
            compactIndex: 0,
            compactLabel: nil,
            now: now,
            sessions: frame.sessions,
            sessionsNow: now,
            showsAccounts: true,
            sessionsConnected: true,
            // "When active" keeps timing real work, so its linger is right after the stop.
            activeCount: sessions.viewState.activeCount,
            isDemo: true
        )
    }
```

4g. Recap and demo calls that used `presenter` now use `composer.presenter`; `checkRecap()` uses `composer.hasNotchScreen`:

```swift
        guard let recorder, settings.isEnabled, composer.hasNotchScreen,
              let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: RecapCalendar.weekStart(of: clock(), calendar: calendar))
        else { return }
```

Replace every remaining `presenter.` in the file with `composer.presenter.` (in `checkRecap`, `dismissRecap`, `demoDidStart`, `demoTick`, `demoDidStop`). In `demoTick`, replace `showDemoFrame()` with `composer.refresh()`. Make `openRecapDetails()` internal (drop `private`), since `AgentSource` requires it. Delete `noteAlerts()`, `flash(_:)` and `lingers(isActive:)` from the controller (they live in the composer now).

- [ ] **Step 5: Run the new test and the Claude suites**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/NotchComposerTests -only-testing:WorkdeckTests/ClaudeCodeControllerTests -only-testing:WorkdeckTests/RecapControllerTests -only-testing:WorkdeckTests/AccountsCompositionTests -only-testing:WorkdeckTests/ClaudeCodeDemoControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, with the existing suites unchanged. A failure there is a behavior change: find it with superpowers:systematic-debugging, do not edit those tests.

- [ ] **Step 6: Run the whole suite**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`.

---

### Task 5: The Notch section in Settings

**Files:**
- Create: `Workdeck/Features/Notch/NotchSettingsSection.swift`
- Modify: `Workdeck/Features/ClaudeCode/Limits/ClaudeLimitsSettingsSection.swift`, `Workdeck/Features/ClaudeCode/Sessions/ClaudeSessionsSettingsSection.swift`, `Workdeck/App/SettingsView.swift`
- Modify: `docs/testing.md`, `docs/claude-code.md`, `README.md`

**Interfaces:**
- Consumes: `NotchSettings` (Task 2); `ClaudeCodeController.notchSettingsChanged()` and `settings.isEnabled` (Task 4).
- Produces: `struct NotchSettingsSection: View` with `init(settings: NotchSettings, isNotchEnabled: Bool, onChange: @escaping () -> Void)`.

- [ ] **Step 1: Create the section**

```swift
import SwiftUI

/// Settings for every agent in the notch (Codex spec §3.4).
struct NotchSettingsSection: View {
    @Bindable var settings: NotchSettings
    /// An agent is on, so the notch can show alerts.
    let isNotchEnabled: Bool
    let onChange: () -> Void
    /// Follows screen changes while Settings is open, e.g. the lid opening.
    @State private var hasCameraHousing = NotchPresenter.hasCameraHousingScreen()

    var body: some View {
        Section {
            Picker("Show", selection: $settings.mode) {
                ForEach(LimitsDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if !hasCameraHousing {
                Picker("Without a notch", selection: $settings.notchlessDisplay) {
                    ForEach(NotchlessDisplay.allCases) { display in
                        Text(display.title).tag(display)
                    }
                }
            }
            Picker("First alert at", selection: $settings.firstThreshold) {
                ForEach(NotchSettings.firstThresholdOptions, id: \.self) { value in
                    Text("\(value)%").tag(value)
                }
            }
            Picker("Second alert at", selection: $settings.secondThreshold) {
                ForEach(NotchSettings.secondThresholdOptions(above: settings.firstThreshold), id: \.self) { value in
                    Text("\(value)%").tag(value)
                }
            }
            Toggle("Notify when a limit resets", isOn: $settings.notifyOnReset)
            Toggle("Forecast when limits run out", isOn: $settings.showForecast)
            Group {
                Toggle("Notify when a session finishes", isOn: $settings.notifyWhenFinished)
                if settings.notifyWhenFinished {
                    Picker("After working for", selection: $settings.finishedAfterMinutes) {
                        ForEach(NotchSettings.finishedAfterOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                }
                Toggle("Notify when a session needs you", isOn: $settings.notifyWhenNeedsYou)
            }
            // Alerts appear in the notch, which only shows while a tool is on.
            .disabled(!isNotchEnabled)
            Toggle("Keep Mac awake while an agent works", isOn: $settings.keepAwakeWhileWorking)
            if !isNotchEnabled {
                Text("Turn on Claude Code in the menu bar popover to see the notch and its alerts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsHeader("Notch", symbol: "menubar.rectangle", color: .teal)
        } footer: {
            Text("Applies to every tool that shows in the notch. Keeping the Mac awake uses a standard power assertion; the display still sleeps, and a closed lid still sleeps unless Closed-Lid Mode is on.")
                .foregroundStyle(.secondary)
        }
        .onChange(of: settings.mode) { onChange() }
        .onChange(of: settings.firstThreshold) { onChange() }
        .onChange(of: settings.secondThreshold) { onChange() }
        .onChange(of: settings.showForecast) { onChange() }
        .onChange(of: settings.notchlessDisplay) { onChange() }
        .onChange(of: settings.keepAwakeWhileWorking) { onChange() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasCameraHousing = NotchPresenter.hasCameraHousingScreen()
        }
    }
}
```

- [ ] **Step 2: Trim the Claude sections**

In `ClaudeLimitsSettingsSection.swift` remove: the `hasCameraHousing` state, the "Without a notch" picker, the whole `if controller.hasDataSource { … }` block (Show, both alert pickers, the reset and forecast toggles), and every `.onChange` and the `.onReceive` modifiers. Keep the status line row, the review, the usage API toggle and its status, the header and the footer.

In `ClaudeSessionsSettingsSection.swift` remove the whole `if controller.isHooksConnected { … }` block (keep-awake, notify toggles and the caption) and the `.onChange(of: settings.keepAwakeWhileWorking)` modifier; the `@Bindable var settings` line goes too if nothing else uses it.

- [ ] **Step 3: Place the section** in `SettingsView.body`, right after the Closed-Lid Mode section:

```swift
            NotchSettingsSection(
                settings: claudeCode.settings.notch,
                isNotchEnabled: claudeCode.settings.isEnabled,
                onChange: claudeCode.notchSettingsChanged
            )
```

- [ ] **Step 4: Build and run the whole suite**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Docs**

- `docs/testing.md`: add before `## Virtual Notch Checklist`:

```markdown
## Notch Settings Checklist

| # | Case | Steps | Expected |
|---|------|-------|----------|
| N1 | Settings moved | Open Settings; check the Notch section; change Show, the alert thresholds, the forecast and Keep Mac awake; relaunch Workdeck. | The Notch section sits after Closed-Lid Mode with Show, Without a notch (lid closed only), both alert thresholds, reset alert, forecast, finished and needs-you alerts and keep-awake; the Claude Code sections no longer have them. Every change shows at once in the notch (and `pmset -g assertions` for keep-awake) and survives the relaunch, as do the values chosen before this version. |
```

- `docs/claude-code.md`: replace "Settings → **Without a notch**" with "Settings → Notch → **Without a notch**", and every "in Settings" that refers to the alert thresholds, forecast, "When active" or the session alerts and keep-awake with "in Settings → Notch".
- `README.md`: in Setup and Things to Try, change any path to those settings to "Settings → Notch".

---

### Task 6: The app shares one composer

**Files:**
- Modify: `Workdeck/App/AppDelegate.swift`, `CLAUDE.md`

**Interfaces:**
- Consumes: `NotchComposer` (Task 3), `ClaudeCodeController.init(settings:limits:sessions:composer:clock:recapStore:calendar:)` (Task 4), `NotchSettings` (Task 2).
- Produces: `AppDelegate.notch: NotchComposer` (plans 2 and 3 register Codex into it).

- [ ] **Step 1: Wire the composer**

In `AppDelegate`, add before `claudeCode`:

```swift
    /// The notch every agent tool feeds (Codex spec §4).
    private(set) lazy var notch: NotchComposer = {
        let settings = NotchSettings()
        let demo = self.demo
        return NotchComposer(
            settings: settings,
            // The demo always draws a notch, the virtual one on a screen without one (demo mode spec §2.3).
            presenter: NotchPresenter(screen: { [demo] in
                NotchPresenter.targetScreen(notchless: demo.isActive ? .virtualNotch : settings.notchlessDisplay)
            })
        )
    }()
```

In the `claudeCode` initializer: `let settings = ClaudeCodeSettings(notch: notch.settings)`, drop the local `demo` and the `presenter:` argument, and pass `composer: notch` instead.

- [ ] **Step 2: Build and run the whole suite**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: `CLAUDE.md`** — in the `Workdeck/Features/Notch/` bullet (Task 1) add: "`NotchComposer` owns the presenter and decides what shows; each agent tool conforms to `AgentSource` and hands it an `AgentNotchPart`. `NotchSettings` holds the settings every agent shares (Settings → Notch) under the keys Claude Code's settings used." In the `Workdeck/Features/ClaudeCode/` bullet replace "composes `Limits/` … into the notch, popover row and menu bar" with "composes `Limits/` … into its popover row and its part of the notch".

- [ ] **Step 4: Live check by the user** after `make install`: the notch, alerts, peek, "When active", the recap and the demo behave as before; row N1 of `docs/testing.md`. Then, on "коммить":

```bash
git add -A Workdeck WorkdeckTests docs README.md CLAUDE.md specs/2026-10-15-codex-support-design.md plans/2026-10-15-shared-notch.md
git commit -m "refactor(notch): share the notch through a composer and a Notch section"
```
