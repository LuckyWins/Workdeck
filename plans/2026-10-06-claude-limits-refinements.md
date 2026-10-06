# Claude Code Limits — Refinements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Keychain password prompts by reading Claude Code's token through `/usr/bin/security`, pause usage polling while the screen is locked or asleep, add a manual refresh button, show only data-source settings until a source is on, and forecast when a limit will run out.

**Architecture:** `SecurityCLICredentialsReader` runs `security` through an injected `ProcessRunning`. `SessionActivityMonitor` reports lock/sleep; the controller pauses `UsagePoller` and refreshes on unlock. `UsagePoller.refreshNow()` backs the popover button. `UsageForecast` (pure) computes exhaustion from the current window and an in-memory `UsageHistory`; the controller puts the result into `LimitsViewState.forecasts`, and the expanded notch renders it.

**Tech Stack:** Swift 6.4, Foundation `Process`, AppKit notifications, Observation, SwiftUI, Swift Testing.

**Spec:** `specs/2026-10-05-claude-limits-design.md` — §11.

## Global Constraints

- Token command: `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`, fixed arguments, stdout through a pipe, stderr discarded, timeout 10 s. Exit 0 → token, 44 → `notFound`, timeout or other → `accessDenied`.
- The token never appears in process arguments, logs, or error text. Tests never run the real `security`, touch the Keychain, call the network, or touch `~/.claude` or the real snapshot.
- Pause on `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` and `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification`; on becoming active call `pollIfStale()` (API on only).
- Refresh button: `arrow.clockwise`, borderless, secondary, help "Refresh usage", only when `fetchFromAPI`; progress indicator while fetching; disabled during a 429 pause.
- `keychainDenied` text: "Keychain access denied — click Refresh to try again".
- `showForecast`, UserDefaults key `claudeLimits.showForecast`, default `true`. Toggle label "Forecast when limits run out".
- Forecast: recent window 60 min, minimum recent span 10 min (5-hour only); average-rate minimum elapsed 15 min (5-hour) / 6 h (weekly); only shown when exhaustion is before `resetsAt`.
- Notch text: "runs out ~16:40 · resets 18:00", "runs out ~16:40" in orange; `HH:mm` within 24 h, otherwise `EEE HH:mm`.
- English only in UI, code, comments, docs and commits. Commits: plain imperative sentences, no `Co-Authored-By` trailers, no mention of AI tools.
- New source files are picked up by the file-system-synchronized groups; do not edit `project.pbxproj`.
- Test command: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`; single suite: add `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. `security` hangs (e.g. a prompt nobody answers): the read must give up after the timeout, kill the process, and report `keychainDenied` — test `timesOutAndKillsTheProcess` (Task 1).
2. Samples from before a relaunch or from the future (clock skew between the status line and the app): the recent rate must ignore them and fall back to the average — tests `oldSamplesAreIgnored`, `futureSamplesAreIgnored` (Task 4).
3. A 5-hour reset with history from the previous period: old samples must not produce a negative or inflated rate — tests `otherPeriodSamplesAreIgnored` (Task 4) and `dropsSamplesFromAnotherPeriod` (Task 4).
4. Unlocking while the API is off must not start fetches — test `unlockWithUsageAPIOffDoesNotPoll` (Task 2).
5. Refresh during a 429 pause must not send a request — test `refreshNowRespectsRateLimitPause` (Task 3).

---

### Task 1: Read the token through `/usr/bin/security`

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/UsageAPI/ProcessRunner.swift`
- Modify: `Workdeck/Features/ClaudeLimits/UsageAPI/ClaudeCredentials.swift` (replace `KeychainCredentialsReader`)
- Modify: `Workdeck/App/AppDelegate.swift:19`
- Test: `WorkdeckTests/ClaudeLimits/UsageAPI/SecurityCLICredentialsReaderTests.swift`

**Interfaces:**
- Produces: `ProcessResult { exitCode: Int32; stdout: Data; timedOut: Bool }`, `protocol ProcessRunning: Sendable { func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> ProcessResult }`, `SystemProcessRunner`, `SecurityCLICredentialsReader(runner:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Synchronization
import Testing
@testable import Workdeck

/// Returns a fixed result and records what it was asked to run.
final class FakeProcessRunner: ProcessRunning {
    private let result: ProcessResult
    private let calls = Mutex<[(URL, [String], TimeInterval)]>([])

    init(_ result: ProcessResult) {
        self.result = result
    }

    var lastCall: (URL, [String], TimeInterval)? { calls.withLock { $0.last } }

    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> ProcessResult {
        calls.withLock { $0.append((executable, arguments, timeout)) }
        return result
    }
}

struct SecurityCLICredentialsReaderTests {
    private let json = Data(#"{"claudeAiOauth":{"accessToken":"secret-token","refreshToken":"r"}}"#.utf8) + Data("\n".utf8)

    @Test func runsSecurityWithFixedArguments() throws {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 0, stdout: json, timedOut: false))
        _ = try SecurityCLICredentialsReader(runner: runner).accessToken()
        let call = try #require(runner.lastCall)
        #expect(call.0.path == "/usr/bin/security")
        #expect(call.1 == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        #expect(call.2 == 10)
    }

    @Test func returnsTokenOnSuccess() throws {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 0, stdout: json, timedOut: false))
        #expect(try SecurityCLICredentialsReader(runner: runner).accessToken() == "secret-token")
    }

    @Test func exit44MeansNotFound() {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 44, stdout: Data(), timedOut: false))
        #expect(throws: ClaudeCredentialsError.notFound) {
            try SecurityCLICredentialsReader(runner: runner).accessToken()
        }
    }

    @Test(arguments: [Int32(1), 36, 51, 128, -1])
    func otherExitCodesMeanDenied(code: Int32) {
        let runner = FakeProcessRunner(ProcessResult(exitCode: code, stdout: Data(), timedOut: false))
        #expect(throws: ClaudeCredentialsError.accessDenied) {
            try SecurityCLICredentialsReader(runner: runner).accessToken()
        }
    }

    @Test func timeoutMeansDenied() {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 15, stdout: json, timedOut: true))
        #expect(throws: ClaudeCredentialsError.accessDenied) {
            try SecurityCLICredentialsReader(runner: runner).accessToken()
        }
    }

    @Test func unexpectedOutputIsMalformed() {
        let runner = FakeProcessRunner(ProcessResult(exitCode: 0, stdout: Data("not json\n".utf8), timedOut: false))
        #expect(throws: ClaudeCredentialsError.malformed) {
            try SecurityCLICredentialsReader(runner: runner).accessToken()
        }
    }
}

/// Runs harmless system binaries only; never `security`.
struct SystemProcessRunnerTests {
    @Test func capturesStdoutAndExitCode() {
        let result = SystemProcessRunner().run(URL(filePath: "/bin/sh"), arguments: ["-c", "printf hello; echo oops >&2; exit 3"], timeout: 5)
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello")
        #expect(!result.timedOut)
    }

    @Test(.timeLimit(.minutes(1)))
    func timesOutAndKillsTheProcess() {
        let start = Date()
        let result = SystemProcessRunner().run(URL(filePath: "/bin/sleep"), arguments: ["30"], timeout: 0.3)
        #expect(result.timedOut)
        #expect(result.stdout.isEmpty)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func missingExecutableFails() {
        let result = SystemProcessRunner().run(URL(filePath: "/nonexistent/tool"), arguments: [], timeout: 1)
        #expect(result.exitCode == -1)
        #expect(!result.timedOut)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SecurityCLICredentialsReaderTests -only-testing:WorkdeckTests/SystemProcessRunnerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `ProcessRunning`, `ProcessResult`, `SystemProcessRunner`, `SecurityCLICredentialsReader` not found.

- [ ] **Step 3: Create `ProcessRunner.swift`**

```swift
import Foundation

nonisolated struct ProcessResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: Data
    var timedOut: Bool
}

nonisolated protocol ProcessRunning: Sendable {
    /// Runs the executable to completion, or kills it after `timeout`. Blocks; call it off the main actor.
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> ProcessResult
}

nonisolated struct SystemProcessRunner: ProcessRunning {
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: Data(), timedOut: false)
        }
        // The expected output is a few kilobytes, well under the pipe buffer, so reading after exit cannot deadlock;
        // anything larger blocks the child until the timeout kills it.
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            return ProcessResult(exitCode: process.isRunning ? -1 : process.terminationStatus, stdout: Data(), timedOut: true)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(exitCode: process.terminationStatus, stdout: data, timedOut: false)
    }
}
```

- [ ] **Step 4: Replace `KeychainCredentialsReader` in `ClaudeCredentials.swift`**

Remove `import Security` and the whole `KeychainCredentialsReader` struct. Change the protocol comment to:

```swift
nonisolated protocol ClaudeCredentialsReading: Sendable {
    /// Blocks while the token is read; call it off the main actor.
    func accessToken() throws -> String
}
```

Append:

```swift
/// Reads Claude Code's OAuth token by running `security`. Claude Code recreates its Keychain item on every
/// token refresh, which drops apps from the item's partition list and makes `SecItemCopyMatching` ask for the
/// login password; `/usr/bin/security` stays in that list, so it never prompts. The token is returned to the
/// caller only and never stored.
nonisolated struct SecurityCLICredentialsReader: ClaudeCredentialsReading {
    static let executable = URL(filePath: "/usr/bin/security")
    static let arguments = ["find-generic-password", "-s", ClaudeCredentials.keychainService, "-w"]
    static let timeout: TimeInterval = 10
    /// `security` exits with 44 (errSecItemNotFound truncated) when there is no such item.
    static let itemNotFoundExitCode: Int32 = 44

    var runner: any ProcessRunning = SystemProcessRunner()

    func accessToken() throws -> String {
        let result = runner.run(Self.executable, arguments: Self.arguments, timeout: Self.timeout)
        guard !result.timedOut else { throw ClaudeCredentialsError.accessDenied }
        switch result.exitCode {
        case 0:
            return try ClaudeCredentials.accessToken(fromCredentialsJSON: result.stdout)
        case Self.itemNotFoundExitCode:
            throw ClaudeCredentialsError.notFound
        default:
            throw ClaudeCredentialsError.accessDenied
        }
    }
}
```

(`JSONSerialization` accepts the trailing newline `security -w` prints, so no trimming is needed; `returnsTokenOnSuccess` covers it.)

- [ ] **Step 5: Wire it in `AppDelegate.swift`**

Replace `credentials: KeychainCredentialsReader(),` with `credentials: SecurityCLICredentialsReader(),`.

- [ ] **Step 6: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`, no "recorded an issue".

- [ ] **Step 7: Commit**

```bash
git add Workdeck/Features/ClaudeLimits/UsageAPI Workdeck/App/AppDelegate.swift WorkdeckTests/ClaudeLimits/UsageAPI/SecurityCLICredentialsReaderTests.swift
git commit -m "Read the Claude Code token through the security tool to avoid Keychain prompts"
```

---

### Task 2: Pause polling while the screen is locked or asleep

**Files:**
- Create: `Workdeck/Features/ClaudeLimits/UsageAPI/SessionActivityMonitor.swift`
- Modify: `Workdeck/Features/ClaudeLimits/UsageAPI/UsagePoller.swift`
- Modify: `Workdeck/Features/ClaudeLimits/ClaudeLimitsController.swift`
- Modify: `Workdeck/App/AppDelegate.swift`
- Test: `WorkdeckTests/ClaudeLimits/SessionActivityMonitorTests.swift`, `WorkdeckTests/ClaudeLimits/UsageAPI/UsagePollerTests.swift`, `WorkdeckTests/ClaudeLimits/ClaudeLimitsControllerTests.swift`

**Interfaces:**
- Produces: `enum SessionActivityEvent { locked, unlocked, screensSlept, screensWoke }`; `protocol SessionActivityMonitoring: AnyObject { var isActive: Bool { get }; var onChange: ((Bool) -> Void)? { get set }; func start() }`; `SessionActivityMonitor.handle(_:)`; `UsagePolling.setPaused(_ paused: Bool)`; `ClaudeLimitsController.init(..., activity: any SessionActivityMonitoring, ...)`.

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeLimits/SessionActivityMonitorTests.swift`:

```swift
import Testing
@testable import Workdeck

@MainActor
struct SessionActivityMonitorTests {
    @Test func activeOnlyWhenUnlockedAndAwake() {
        let monitor = SessionActivityMonitor()
        var changes: [Bool] = []
        monitor.onChange = { changes.append($0) }
        #expect(monitor.isActive)
        monitor.handle(.screensSlept)
        monitor.handle(.locked)
        #expect(!monitor.isActive)
        monitor.handle(.screensWoke)
        #expect(!monitor.isActive)
        monitor.handle(.unlocked)
        #expect(monitor.isActive)
        #expect(changes == [false, true])
    }

    @Test func repeatedEventsDoNotNotify() {
        let monitor = SessionActivityMonitor()
        var changes: [Bool] = []
        monitor.onChange = { changes.append($0) }
        monitor.handle(.unlocked)
        monitor.handle(.screensWoke)
        #expect(changes.isEmpty)
    }
}
```

Add to `UsagePollerTests` (inside the struct):

```swift
    @Test func pausedPollerSkipsPollsUntilResumed() async {
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (5, 3600))))
        let poller = makePoller()
        poller.setPaused(true)
        poller.start()
        await poller.pollTask?.value
        poller.pollIfStale()
        poller.poll()
        await poller.pollTask?.value
        #expect(transport.requests.isEmpty)
        poller.setPaused(false)
        poller.pollIfStale()
        await poller.pollTask?.value
        #expect(transport.requests.count == 1)
    }
```

In `ClaudeLimitsControllerTests.swift`, add a fake and extend `FakePoller`:

```swift
@MainActor
final class FakeActivity: SessionActivityMonitoring {
    var isActive = true
    var onChange: ((Bool) -> Void)?
    private(set) var startCount = 0

    func start() { startCount += 1 }

    func send(_ active: Bool) {
        isActive = active
        onChange?(active)
    }
}
```

In `FakePoller` add:

```swift
    private(set) var pausedValues: [Bool] = []
    func setPaused(_ paused: Bool) { pausedValues.append(paused) }
```

Add `let activity = FakeActivity()` to the suite, pass `activity: activity` in `makeController` (after `poller: poller,`), and add tests:

```swift
    @Test func lockPausesPollerAndUnlockRefreshes() {
        settings.fetchFromAPI = true
        let (controller, _) = makeController()
        controller.start()
        #expect(activity.startCount == 1)
        #expect(poller.pausedValues == [false])
        activity.send(false)
        #expect(poller.pausedValues.last == true)
        activity.send(true)
        #expect(poller.pausedValues.last == false)
        #expect(poller.staleCheckCount == 1)
    }

    @Test func unlockWithUsageAPIOffDoesNotPoll() {
        let (controller, _) = makeController()
        controller.start()
        activity.send(false)
        activity.send(true)
        #expect(poller.staleCheckCount == 0)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/SessionActivityMonitorTests -only-testing:WorkdeckTests/UsagePollerTests -only-testing:WorkdeckTests/ClaudeLimitsControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `SessionActivityMonitor`, `SessionActivityMonitoring`, `setPaused`, `activity:` not found.

- [ ] **Step 3: Create `SessionActivityMonitor.swift`**

```swift
import AppKit

nonisolated enum SessionActivityEvent: Sendable {
    case locked
    case unlocked
    case screensSlept
    case screensWoke
}

protocol SessionActivityMonitoring: AnyObject {
    /// False while the screen is locked or the displays sleep (including a closed lid in Closed-Lid Mode).
    var isActive: Bool { get }
    var onChange: ((Bool) -> Void)? { get set }
    func start()
}

/// Tracks whether someone can be looking at the screen, so background work can wait.
final class SessionActivityMonitor: SessionActivityMonitoring {
    var onChange: ((Bool) -> Void)?

    private var isLocked = false
    private var screensAsleep = false
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    var isActive: Bool {
        !isLocked && !screensAsleep
    }

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(distributed, "com.apple.screenIsLocked", .locked)
        observe(distributed, "com.apple.screenIsUnlocked", .unlocked)
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue, .screensSlept)
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue, .screensWoke)
    }

    func handle(_ event: SessionActivityEvent) {
        let wasActive = isActive
        switch event {
        case .locked: isLocked = true
        case .unlocked: isLocked = false
        case .screensSlept: screensAsleep = true
        case .screensWoke: screensAsleep = false
        }
        if isActive != wasActive {
            onChange?(isActive)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ event: SessionActivityEvent) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        observers.append((center, token))
    }
}
```

- [ ] **Step 4: Add pausing to `UsagePoller`**

In `protocol UsagePolling` add:

```swift
    /// While paused (screen locked or asleep) timer ticks and stale checks do nothing.
    func setPaused(_ paused: Bool)
```

In `UsagePoller` add the state next to `isBlockedByDenial`:

```swift
    @ObservationIgnored private var isPaused = false
```

the method after `stop()`:

```swift
    func setPaused(_ paused: Bool) {
        isPaused = paused
    }
```

and change the guard in `poll()` to:

```swift
        guard isRunning, !isPaused, !isBlockedByDenial, pollTask == nil else { return }
```

- [ ] **Step 5: Wire the monitor into `ClaudeLimitsController`**

Add the stored property after `poller`:

```swift
    @ObservationIgnored private let activity: any SessionActivityMonitoring
```

Add the init parameter after `poller: any UsagePolling,`:

```swift
        activity: any SessionActivityMonitoring,
```

and `self.activity = activity` after `self.poller = poller`. In `start()`, replace

```swift
        store.startWatching()
        if settings.fetchFromAPI {
            poller.start()
        }
```

with

```swift
        store.startWatching()
        activity.onChange = { [weak self] active in self?.sessionActivityChanged(active) }
        activity.start()
        poller.setPaused(!activity.isActive)
        if settings.fetchFromAPI {
            poller.start()
        }
```

and add after `popoverOpened()`:

```swift
    /// No polling while the screen is locked or asleep; catch up as soon as someone is back.
    private func sessionActivityChanged(_ active: Bool) {
        poller.setPaused(!active)
        if active, settings.fetchFromAPI {
            poller.pollIfStale()
        }
    }
```

- [ ] **Step 6: Wire it in `AppDelegate.swift`**

In the `ClaudeLimitsController(` call, after the `poller: UsagePoller(...)` argument add `,` and:

```swift
        activity: SessionActivityMonitor()
```

- [ ] **Step 7: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Workdeck/Features/ClaudeLimits Workdeck/App/AppDelegate.swift WorkdeckTests/ClaudeLimits
git commit -m "Pause usage polling while the screen is locked or asleep"
```

---

### Task 3: Manual refresh

**Files:**
- Modify: `Workdeck/Features/ClaudeLimits/UsageAPI/UsagePoller.swift`
- Modify: `Workdeck/Features/ClaudeLimits/ClaudeLimitsController.swift`
- Modify: `Workdeck/Features/ClaudeLimits/ClaudeLimitsRow.swift`
- Modify: `Workdeck/Features/ClaudeLimits/LimitsText.swift:86-87`
- Test: `WorkdeckTests/ClaudeLimits/UsageAPI/UsagePollerTests.swift`, `WorkdeckTests/ClaudeLimits/ClaudeLimitsControllerTests.swift`, `WorkdeckTests/ClaudeLimits/LimitsTextTests.swift`

**Interfaces:**
- Consumes: `UsagePolling.setPaused(_:)` (Task 2).
- Produces: `UsagePolling.isFetching: Bool`, `UsagePolling.refreshNow()`, `ClaudeLimitsController.refreshNow()`, `.isFetching`, `.canRefreshNow`.

- [ ] **Step 1: Write the failing tests**

Add to `UsagePollerTests`:

```swift
    @Test func refreshNowIgnoresTheOneMinuteThrottle() async {
        var now = fixedNow
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (1, 3600))))
        transport.enqueue(.init(status: 200, body: usageBody(fiveHour: (2, 3600))))
        let poller = makePoller { now }
        poller.start()
        await poller.pollTask?.value
        now = fixedNow.addingTimeInterval(10)
        poller.refreshNow()
        await poller.pollTask?.value
        #expect(transport.requests.count == 2)
    }

    @Test func refreshNowRetriesAfterKeychainDenial() async {
        let credentials = ScriptedCredentials(failingWith: .accessDenied)
        let poller = makePoller(credentials: credentials)
        poller.start()
        await poller.pollTask?.value
        poller.poll()
        await poller.pollTask?.value
        #expect(credentials.readCount == 1)
        poller.refreshNow()
        await poller.pollTask?.value
        #expect(credentials.readCount == 2)
    }

    @Test func refreshNowRespectsRateLimitPause() async {
        var now = fixedNow
        transport.enqueue(.init(status: 429, body: "", headers: ["Retry-After": "300"]))
        let poller = makePoller { now }
        poller.start()
        await poller.pollTask?.value
        now = fixedNow.addingTimeInterval(60)
        poller.refreshNow()
        await poller.pollTask?.value
        #expect(transport.requests.count == 1)
    }

    @Test func refreshNowDoesNothingWhenStopped() async {
        let poller = makePoller()
        poller.refreshNow()
        await poller.pollTask?.value
        #expect(transport.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func isFetchingWhileAPollRuns() async throws {
        let credentials = ScriptedCredentials(failingWith: .notFound, held: true)
        let poller = makePoller(credentials: credentials)
        #expect(!poller.isFetching)
        poller.start()
        #expect(poller.isFetching)
        while credentials.readCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        credentials.release()
        await poller.pollTask?.value
        #expect(!poller.isFetching)
    }
```

In `FakePoller` add:

```swift
    var isFetching = false
    private(set) var refreshCount = 0
    func refreshNow() { refreshCount += 1 }
```

Add to `ClaudeLimitsControllerTests`:

```swift
    @Test func refreshNowOnlyWithUsageAPI() {
        let (controller, _) = makeController()
        controller.refreshNow()
        #expect(poller.refreshCount == 0)
        settings.fetchFromAPI = true
        controller.refreshNow()
        #expect(poller.refreshCount == 1)
    }

    @Test func refreshIsUnavailableWhileFetchingOrRateLimited() {
        settings.fetchFromAPI = true
        let (controller, _) = makeController()
        #expect(controller.canRefreshNow)
        poller.isFetching = true
        #expect(!controller.canRefreshNow)
        poller.isFetching = false
        poller.status = .rateLimited(until: fixedNow.addingTimeInterval(60))
        #expect(!controller.canRefreshNow)
        poller.status = .rateLimited(until: fixedNow.addingTimeInterval(-1))
        #expect(controller.canRefreshNow)
    }
```

In `LimitsTextTests`, add next to the other `pollerStatusText` expectations:

```swift
        #expect(LimitsText.pollerStatusText(.keychainDenied, now: fixedNow, calendar: utc) == "Keychain access denied — click Refresh to try again")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/UsagePollerTests -only-testing:WorkdeckTests/ClaudeLimitsControllerTests -only-testing:WorkdeckTests/LimitsTextTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `refreshNow`, `isFetching`, `canRefreshNow` not found.

- [ ] **Step 3: Add `refreshNow()` and `isFetching` to `UsagePoller`**

In `protocol UsagePolling` add:

```swift
    /// True while a fetch is in flight.
    var isFetching: Bool { get }
    /// The refresh button: polls now despite the 1-minute throttle and retries after a Keychain denial.
    func refreshNow()
```

Change the `keychainDenied` comment in `UsagePollerStatus` to:

```swift
    /// Reading the token failed or timed out; polling waits until Refresh or the setting is toggled.
```

In `UsagePoller` add after `private(set) var status`:

```swift
    private(set) var isFetching = false
```

change the comment on `isBlockedByDenial` to `/// After a failed token read, stop retrying on a schedule until the user asks.`, add after `pollIfStale()`:

```swift
    func refreshNow() {
        guard isRunning else { return }
        isBlockedByDenial = false
        poll()
    }
```

and in `poll()` replace the task creation with:

```swift
        lastAttempt = now
        isFetching = true
        pollTask = Task {
            await performPoll(now: now)
            isFetching = false
            pollTask = nil
        }
```

In `performPoll`, change the comment above the detached read to `// Reading the token runs a process, so keep it off the main actor.`

- [ ] **Step 4: Add controller API**

In `ClaudeLimitsController` after `pollerStatus`:

```swift
    var isFetching: Bool {
        poller.isFetching
    }

    /// The refresh button is off while a fetch runs or Anthropic asked us to wait.
    var canRefreshNow: Bool {
        if poller.isFetching {
            return false
        }
        if case let .rateLimited(until) = poller.status, until > store.now {
            return false
        }
        return true
    }
```

and after `popoverOpened()`:

```swift
    func refreshNow() {
        guard settings.fetchFromAPI else { return }
        poller.refreshNow()
    }
```

- [ ] **Step 5: Update the denial text in `LimitsText.pollerStatusText`**

```swift
        case .keychainDenied:
            "Keychain access denied — click Refresh to try again"
```

- [ ] **Step 6: Add the button to `ClaudeLimitsRow`**

Replace `Spacer(minLength: 8)` and the toggle block's leading part with:

```swift
            Spacer(minLength: 8)

            if controller.settings.fetchFromAPI {
                Group {
                    if controller.isFetching {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Button {
                            controller.refreshNow()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(!controller.canRefreshNow)
                        .help("Refresh usage")
                    }
                }
                .frame(width: 16, height: 16)
            }

            Toggle("Claude Code Limits", isOn: Binding(
```

(The rest of the toggle is unchanged.)

- [ ] **Step 7: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Workdeck/Features/ClaudeLimits WorkdeckTests/ClaudeLimits
git commit -m "Add a refresh button for usage fetched from Anthropic"
```

---

### Task 4: Forecast model

**Files:**
- Modify: `ClaudeUsage/UsageSnapshot.swift` (add `UsageWindowKind.duration`)
- Create: `Workdeck/Features/ClaudeLimits/UsageForecast.swift`
- Modify: `Workdeck/Features/ClaudeLimits/ClaudeLimitsSettings.swift`
- Modify: `Workdeck/Features/ClaudeLimits/LimitsText.swift`
- Test: `WorkdeckTests/ClaudeLimits/UsageForecastTests.swift`, `WorkdeckTests/ClaudeLimits/ClaudeLimitsSettingsTests.swift`

**Interfaces:**
- Produces: `UsageWindowKind.duration: TimeInterval`; `UsageSample { date: Date; percent: Double; resetsAt: Date }`; `UsageForecast.exhaustion(window: UsageWindow, samples: [UsageSample], now: Date) -> Date?`; `UsageHistory { samples: [UsageSample]; mutating func record(_ window: UsageWindow?, at date: Date) }`; `ClaudeLimitsSettings.showForecast: Bool`; `LimitsText.forecastText(_:now:calendar:)` → "runs out ~16:40"; `LimitsText.resetClockText(_:now:calendar:)` → "resets 18:00".

- [ ] **Step 1: Write the failing tests**

`WorkdeckTests/ClaudeLimits/UsageForecastTests.swift`:

```swift
import Foundation
import Testing
@testable import Workdeck

private func near(_ date: Date?, _ expected: Date) -> Bool {
    guard let date else { return false }
    return abs(date.timeIntervalSince(expected)) < 0.01
}

private func sample(_ secondsAgo: TimeInterval, _ percent: Double, resetsIn: TimeInterval = 3600) -> UsageSample {
    UsageSample(date: fixedNow.addingTimeInterval(-secondsAgo), percent: percent, resetsAt: fixedNow.addingTimeInterval(resetsIn))
}

struct UsageForecastTests {
    // A 5-hour window resetting in 1 h started 4 h ago. At 90 % the average rate is 22.5 %/h,
    // so the last 10 % takes 1600 s.
    @Test func averageRateForFiveHourWindow() {
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 90), samples: [], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1600)))
    }

    @Test func noForecastWhenTheLimitLastsUntilReset() {
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 20), samples: [], now: fixedNow) == nil)
    }

    @Test func noForecastInTheFirstFifteenMinutes() {
        let young = window(.fiveHour, 50, resetsIn: 5 * 3600 - 600)
        #expect(UsageForecast.exhaustion(window: young, samples: [], now: fixedNow) == nil)
    }

    // 40 % → 70 % in the last 30 min is 1 %/min, so the last 30 % takes 30 min; the average rate alone
    // (70 % over 4 h) would last past the reset.
    @Test func recentRateWinsForFiveHourWindow() {
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 70), samples: [sample(1800, 40)], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1800)))
    }

    @Test func idleRecentHistoryMeansNoForecast() {
        // The average rate alone would forecast 758 s.
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 95), samples: [sample(1800, 95)], now: fixedNow) == nil)
    }

    @Test func shortHistoryFallsBackToAverage() {
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 90), samples: [sample(300, 80)], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1600)))
    }

    @Test func oldSamplesAreIgnored() {
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 90), samples: [sample(7200, 10)], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1600)))
    }

    @Test func futureSamplesAreIgnored() {
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 90), samples: [sample(-60, 10)], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1600)))
    }

    @Test func otherPeriodSamplesAreIgnored() {
        let previous = sample(1800, 99, resetsIn: 3600 - 5 * 3600)
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 90), samples: [previous], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1600)))
    }

    // A weekly window resetting in 1 day started 6 days ago. 90 % over 6 days is 15 %/day,
    // so the last 10 % takes 16 h.
    @Test func weeklyUsesAverageRateAndIgnoresSamples() {
        let weekly = window(.sevenDay, 90, resetsIn: 86_400)
        let result = UsageForecast.exhaustion(window: weekly, samples: [sample(1800, 10, resetsIn: 86_400)], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(16 * 3600)))
    }

    @Test func noWeeklyForecastInTheFirstSixHours() {
        let young = window(.sevenDay, 30, resetsIn: 7 * 86_400 - 3 * 3600)
        #expect(UsageForecast.exhaustion(window: young, samples: [], now: fixedNow) == nil)
    }

    @Test func noForecastAtTheLimitExpiredOrUnused() {
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 100), samples: [], now: fixedNow) == nil)
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 90, resetsIn: -1), samples: [], now: fixedNow) == nil)
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 0), samples: [], now: fixedNow) == nil)
    }
}

struct UsageHistoryTests {
    @Test func recordsFiveHourSamplesOncePerSnapshot() {
        var history = UsageHistory()
        history.record(window(.fiveHour, 10), at: fixedNow)
        history.record(window(.fiveHour, 10), at: fixedNow)
        history.record(window(.fiveHour, 12), at: fixedNow.addingTimeInterval(60))
        history.record(nil, at: fixedNow.addingTimeInterval(120))
        history.record(window(.sevenDay, 50), at: fixedNow.addingTimeInterval(180))
        #expect(history.samples.map(\.percent) == [10, 12])
    }

    @Test func dropsSamplesOlderThanAnHour() {
        var history = UsageHistory()
        history.record(window(.fiveHour, 10, resetsIn: 7200), at: fixedNow)
        history.record(window(.fiveHour, 20, resetsIn: 7200), at: fixedNow.addingTimeInterval(3601))
        #expect(history.samples.map(\.percent) == [20])
    }

    @Test func dropsSamplesFromAnotherPeriod() {
        var history = UsageHistory()
        history.record(window(.fiveHour, 90, resetsIn: 60), at: fixedNow)
        history.record(window(.fiveHour, 2, resetsIn: 5 * 3600 + 60), at: fixedNow.addingTimeInterval(120))
        #expect(history.samples.map(\.percent) == [2])
    }
}

struct LimitsForecastTextTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    @Test func forecastText() {
        #expect(LimitsText.forecastText(fixedNow.addingTimeInterval(4 * 3600 + 40 * 60), now: fixedNow, calendar: utc) == "runs out ~16:40")
        #expect(LimitsText.forecastText(fixedNow.addingTimeInterval(2 * 86_400), now: fixedNow, calendar: utc) == "runs out ~Wed 12:00")
    }

    @Test func resetClockText() {
        #expect(LimitsText.resetClockText(fixedNow.addingTimeInterval(6 * 3600), now: fixedNow, calendar: utc) == "resets 18:00")
        #expect(LimitsText.resetClockText(fixedNow.addingTimeInterval(3 * 86_400 - 3 * 3600), now: fixedNow, calendar: utc) == "resets Thu 09:00")
    }
}
```

In `ClaudeLimitsSettingsTests.defaults()` add `#expect(settings.showForecast)`; in `persistsEverything()` add `settings.showForecast = false` before the reload and `#expect(!reloaded.showForecast)` after it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/UsageForecastTests -only-testing:WorkdeckTests/UsageHistoryTests -only-testing:WorkdeckTests/LimitsForecastTextTests -only-testing:WorkdeckTests/ClaudeLimitsSettingsTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build errors — `UsageSample`, `UsageForecast`, `UsageHistory`, `forecastText`, `resetClockText`, `showForecast` not found.

- [ ] **Step 3: Add `duration` to `UsageWindowKind` in `ClaudeUsage/UsageSnapshot.swift`**

After `title`:

```swift
    /// How long one period of the window lasts.
    var duration: TimeInterval {
        switch self {
        case .fiveHour: 5 * 60 * 60
        case .sevenDay: 7 * 24 * 60 * 60
        }
    }
```

- [ ] **Step 4: Create `UsageForecast.swift`**

```swift
import Foundation

/// One observation of the 5-hour window, used for its recent rate.
nonisolated struct UsageSample: Equatable, Sendable {
    var date: Date
    var percent: Double
    var resetsAt: Date
}

/// Predicts when a window reaches 100 % (spec §11.5).
nonisolated enum UsageForecast {
    static let recentSpan: TimeInterval = 60 * 60
    static let minimumRecentSpan: TimeInterval = 10 * 60

    static func minimumElapsed(_ kind: UsageWindowKind) -> TimeInterval {
        switch kind {
        case .fiveHour: 15 * 60
        case .sevenDay: 6 * 60 * 60
        }
    }

    /// When the window runs out at the current pace, or `nil` if it lasts until its reset or the pace is unknown.
    static func exhaustion(window: UsageWindow, samples: [UsageSample], now: Date) -> Date? {
        guard window.usedPercent < 100, window.resetsAt > now else { return nil }
        guard let rate = recentRate(window: window, samples: samples, now: now) ?? averageRate(window: window, now: now),
              rate > 0
        else { return nil }
        let exhaustion = now.addingTimeInterval((100 - window.usedPercent) / rate)
        return exhaustion < window.resetsAt ? exhaustion : nil
    }

    /// Percent per second since the oldest sample of the last hour; `nil` without enough history.
    private static func recentRate(window: UsageWindow, samples: [UsageSample], now: Date) -> Double? {
        guard window.kind == .fiveHour else { return nil }
        let oldest = samples
            .filter { sample in
                abs(sample.resetsAt.timeIntervalSince(window.resetsAt)) <= UsageSnapshot.samePeriodTolerance
                    && sample.date <= now
                    && now.timeIntervalSince(sample.date) <= recentSpan
            }
            .min { $0.date < $1.date }
        guard let oldest else { return nil }
        let span = now.timeIntervalSince(oldest.date)
        guard span >= minimumRecentSpan else { return nil }
        return (window.usedPercent - oldest.percent) / span
    }

    /// Percent per second since the window started.
    private static func averageRate(window: UsageWindow, now: Date) -> Double? {
        let start = window.resetsAt.addingTimeInterval(-window.kind.duration)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= minimumElapsed(window.kind) else { return nil }
        return window.usedPercent / elapsed
    }
}

/// Recent 5-hour samples, kept in memory only; empty after a relaunch.
nonisolated struct UsageHistory: Equatable, Sendable {
    private(set) var samples: [UsageSample] = []

    /// Adds the snapshot's 5-hour window once per snapshot time and drops stale or other-period samples.
    mutating func record(_ window: UsageWindow?, at date: Date) {
        guard let window, window.kind == .fiveHour else { return }
        samples.removeAll { sample in
            abs(sample.resetsAt.timeIntervalSince(window.resetsAt)) > UsageSnapshot.samePeriodTolerance
                || date.timeIntervalSince(sample.date) > UsageForecast.recentSpan
        }
        guard !samples.contains(where: { $0.date == date }) else { return }
        samples.append(UsageSample(date: date, percent: window.usedPercent, resetsAt: window.resetsAt))
    }
}
```

- [ ] **Step 5: Add `showForecast` to `ClaudeLimitsSettings`**

In `Keys` add `static let showForecast = "claudeLimits.showForecast"`. After `fetchFromAPI` add:

```swift
    /// Show when a limit will run out at the current pace (expanded notch).
    var showForecast: Bool {
        didSet { defaults.set(showForecast, forKey: Keys.showForecast) }
    }
```

In `init` after `fetchFromAPI = …` add:

```swift
        showForecast = defaults.object(forKey: Keys.showForecast) as? Bool ?? true
```

- [ ] **Step 6: Add the texts to `LimitsText`**

After `notStartedText`:

```swift
    /// "runs out ~16:40" within a day, otherwise "runs out ~Wed 12:00".
    static func forecastText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        "runs out ~\(clockText(date, now: now, calendar: calendar))"
    }

    /// "resets 18:00" within a day, otherwise "resets Thu 09:00"; shown next to a forecast.
    static func resetClockText(_ resetsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        "resets \(clockText(resetsAt, now: now, calendar: calendar))"
    }

    private static func clockText(_ date: Date, now: Date, calendar: Calendar) -> String {
        formatted(date, date.timeIntervalSince(now) < 24 * 60 * 60 ? "HH:mm" : "EEE HH:mm", calendar: calendar)
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run the Step 2 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add ClaudeUsage/UsageSnapshot.swift Workdeck/Features/ClaudeLimits WorkdeckTests/ClaudeLimits
git commit -m "Add a usage forecast based on recent and average pace"
```

---

### Task 5: Show the forecast in the notch

**Files:**
- Modify: `Workdeck/Features/ClaudeLimits/LimitsPresentation.swift` (`LimitsViewState`)
- Modify: `Workdeck/Features/ClaudeLimits/ClaudeLimitsController.swift`
- Modify: `Workdeck/Features/ClaudeLimits/LimitsNotchViews.swift` (`windowRow`)
- Test: `WorkdeckTests/ClaudeLimits/ClaudeLimitsControllerTests.swift`

**Interfaces:**
- Consumes: `UsageForecast.exhaustion`, `UsageHistory`, `ClaudeLimitsSettings.showForecast`, `LimitsText.forecastText`, `LimitsText.resetClockText` (Task 4).
- Produces: `LimitsViewState.forecasts: [UsageWindowKind: Date]`.

- [ ] **Step 1: Write the failing tests**

Add to `ClaudeLimitsControllerTests`:

```swift
    @Test func passesForecastWhenEnabled() throws {
        connector.status = .connected
        settings.isEnabled = true
        try writeUsage(fiveHour: 90)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        let forecast = try #require(presenter.shown.last?.forecasts[.fiveHour])
        #expect(abs(forecast.timeIntervalSince(fixedNow.addingTimeInterval(1600))) < 0.01)
    }

    @Test func noForecastWhenDisabled() throws {
        connector.status = .connected
        settings.isEnabled = true
        settings.showForecast = false
        try writeUsage(fiveHour: 90)
        let (controller, store) = makeController()
        controller.start()
        store.reload()
        #expect(presenter.shown.last?.forecasts.isEmpty == true)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test -only-testing:WorkdeckTests/ClaudeLimitsControllerTests 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"`
Expected: build error — `forecasts` not found.

- [ ] **Step 3: Add `forecasts` to `LimitsViewState`**

After `var thresholds: [Int]`:

```swift
    /// When each window runs out at the current pace; only windows that run out before their reset.
    var forecasts: [UsageWindowKind: Date] = [:]
```

(`static let hidden` keeps compiling: the memberwise initializer defaults the new property.)

- [ ] **Step 4: Compute forecasts in `ClaudeLimitsController.refresh()`**

Add the stored property after `previousWindows`:

```swift
    @ObservationIgnored private var history = UsageHistory()
```

In `refresh()`, after `defer { previousWindows = current }` add:

```swift
        if let snapshot = store.snapshot {
            history.record(current.first { $0.kind == .fiveHour }, at: snapshot.capturedAt)
        }
        var forecasts: [UsageWindowKind: Date] = [:]
        if settings.showForecast {
            for window in current {
                forecasts[window.kind] = UsageForecast.exhaustion(window: window, samples: history.samples, now: store.now)
            }
        }
```

and pass it to the state:

```swift
        state = LimitsViewState(
            display: display,
            windows: store.allWindows,
            now: store.now,
            age: store.age,
            thresholds: settings.thresholds,
            forecasts: forecasts
        )
```

- [ ] **Step 5: Render it in `LimitsExpandedView.windowRow`**

Replace

```swift
                if let window, isCurrent {
                    Text(LimitsText.resetText(window.resetsAt, now: model.state.now))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                } else if notStarted {
```

with

```swift
                if let window, isCurrent, let forecast = model.state.forecasts[kind] {
                    let runsOut = Text(LimitsText.forecastText(forecast, now: model.state.now)).foregroundStyle(.orange)
                    Text("\(runsOut) · \(LimitsText.resetClockText(window.resetsAt, now: model.state.now))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                } else if let window, isCurrent {
                    Text(LimitsText.resetText(window.resetsAt, now: model.state.now))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                } else if notStarted {
```

- [ ] **Step 6: Run the full test suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|warning:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no warnings.

- [ ] **Step 7: Commit**

```bash
git add Workdeck/Features/ClaudeLimits WorkdeckTests/ClaudeLimits
git commit -m "Show when a limit will run out in the expanded notch"
```

---

### Task 6: Settings layout

**Files:**
- Modify: `Workdeck/Features/ClaudeLimits/ClaudeLimitsSettingsSection.swift`

**Interfaces:**
- Consumes: `ClaudeLimitsSettings.showForecast` (Task 4), `ClaudeLimitsController.hasDataSource`.

SwiftUI layout has no unit tests in this project; verification is the build plus manual scenario L20 (Task 7).

- [ ] **Step 1: Replace the `Section` content**

```swift
        Section {
            LabeledContent("Status line") {
                if controller.isConnected {
                    Button("Disconnect") { controller.disconnect() }
                } else {
                    Button("Connect…") { controller.isConfirmingConnect = true }
                        .disabled(!controller.canConnect)
                }
            }
            Toggle("Fetch usage from Anthropic (unofficial)", isOn: Binding(
                get: { settings.fetchFromAPI },
                set: { controller.setFetchFromAPI($0) }
            ))
            if settings.fetchFromAPI, let status = LimitsText.pollerStatusText(controller.pollerStatus, now: controller.store.now) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(controller.pollerStatus.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            if controller.hasDataSource {
                Picker("Show", selection: $settings.mode) {
                    ForEach(LimitsDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("First alert at", selection: $settings.firstThreshold) {
                    ForEach(ClaudeLimitsSettings.firstThresholdOptions, id: \.self) { value in
                        Text("\(value)%").tag(value)
                    }
                }
                Picker("Second alert at", selection: $settings.secondThreshold) {
                    ForEach(ClaudeLimitsSettings.secondThresholdOptions(above: settings.firstThreshold), id: \.self) { value in
                        Text("\(value)%").tag(value)
                    }
                }
                Toggle("Notify when a limit resets", isOn: $settings.notifyOnReset)
                Toggle("Forecast when limits run out", isOn: $settings.showForecast)
            }
        } header: {
```

(Header and footer unchanged.)

- [ ] **Step 2: Refresh on the new setting**

After `.onChange(of: settings.secondThreshold) { controller.refresh() }` add:

```swift
        .onChange(of: settings.showForecast) { controller.refresh() }
```

- [ ] **Step 3: Drop the Keychain prompt sentence from the disclaimer**

```swift
    static let apiDisclaimer = "Fetching from Anthropic uses the login token Claude Code stores in your Keychain to call an undocumented Anthropic endpoint every 5 minutes. Anthropic's terms do not allow third-party use of Claude Code credentials, and the endpoint may change or stop working."
```

- [ ] **Step 4: Build and run the full test suite**

Run: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|warning:|recorded an issue|Test run with|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, no warnings.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClaudeLimits/ClaudeLimitsSettingsSection.swift
git commit -m "Show Claude Code Limits options only once a data source is on"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md` (Claude Code Limits section)
- Modify: `docs/testing.md` (rows L14, L17; new L18–L21)
- Modify: `CLAUDE.md` (UsageAPI bullet)

- [ ] **Step 1: README**

Replace the "Working only in the VS Code extension." paragraph with:

```markdown
**Working only in the VS Code extension.** Turn on **Fetch usage from Anthropic (unofficial)** in Settings. Workdeck then reads the login token Claude Code stores in your Keychain (through the system `security` tool, so macOS does not ask for your password) and calls an undocumented Anthropic endpoint every 5 minutes, when you open the popover (at most once a minute), and when you click the refresh button in the popover. Polling pauses while the screen is locked or asleep and catches up when you unlock. Workdeck never refreshes or stores the token. Anthropic's terms do not allow third-party use of Claude Code credentials, and the endpoint may change or stop working at any time; use this at your own discretion. If the login expires, open Claude Code to refresh it.
```

After the "Alerts at two configurable thresholds…" bullet add:

```markdown
- A forecast in the expanded view, e.g. `runs out ~16:40 · resets 18:00`, when a limit will run out before it resets at your current pace (can be turned off in Settings).
```

- [ ] **Step 2: `docs/testing.md`**

Replace row L14 with:

```markdown
| L14 | Keychain access | In Settings, turn on "Fetch usage from Anthropic (unofficial)". | No Keychain prompt appears; Settings shows "Last fetched just now". |
```

Replace row L17 with:

```markdown
| L17 | Token refresh | Keep the API on through a day of normal use (Claude Code refreshes its login about every 8 hours), including a night with the lid closed in Closed-Lid Mode. | No Keychain prompt at any point; `/usr/bin/log show --last 1d --predicate 'eventMessage CONTAINS "displaying keychain prompt"'` shows nothing for Workdeck. |
```

Add after L17:

```markdown
| L18 | Paused while locked | API on; lock the screen (Control-Command-Q) for 10+ minutes, then unlock and open Settings. | While locked, "Last fetched" ages past 5 minutes; within seconds of unlocking it shows "just now". |
| L19 | Refresh button | API on; open the popover and click the refresh icon left of the toggle. Turn the API off. | A spinner replaces the icon briefly and the subtitle shows "updated just now"; with the API off the icon is gone. |
| L20 | Settings layout | Disconnect the status line and turn the API off. Then turn either on. | Only "Status line" and the API toggle are shown; turning either on reveals Show, the alert pickers, the reset toggle and the forecast toggle. |
| L21 | Forecast | Use Claude Code heavily in a running 5-hour window, then hover the notch. Turn off "Forecast when limits run out". | When the limit would run out before the reset, the row shows "runs out ~HH:mm · resets HH:mm" with the first part orange; with the setting off, the usual "resets in …" text returns. |
```

- [ ] **Step 3: `CLAUDE.md`**

Append to the `Workdeck/Features/ClaudeLimits/UsageAPI/` bullet:

```markdown
 The token is read by running `/usr/bin/security`, which stays in the Keychain item's partition list; do not switch to `SecItemCopyMatching`, which asks for the login password after every Claude Code token refresh.
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/testing.md CLAUDE.md
git commit -m "Document Keychain access through security, polling pause, refresh, and forecast"
```
