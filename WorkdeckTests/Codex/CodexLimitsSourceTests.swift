import Foundation
import Testing
@testable import Workdeck

@MainActor
final class FakeSessionsWatcher: CodexSessionsWatching {
    var onChange: (@MainActor ([URL]) -> Void)?
    var exists = true
    func start(root: URL, onChange: @escaping @MainActor ([URL]) -> Void) -> Bool {
        self.onChange = onChange
        return exists
    }
    func stop() { onChange = nil }
}

final class FakeFetcher: CodexLimitsFetching, @unchecked Sendable {
    var answer: CodexAppServerAnswer
    private(set) var count = 0
    init(_ answer: CodexAppServerAnswer) { self.answer = answer }
    func fetch(now: Date) async -> CodexAppServerAnswer {
        count += 1
        return answer
    }
}

@MainActor
struct CodexLimitsSourceTests {
    let root = makeTemporaryDirectory().appending(path: "sessions")
    let defaults = UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!
    let watcher = FakeSessionsWatcher()
    let now = Box<Date>(fixedNow)

    private func makeSource(_ answer: CodexAppServerAnswer = .failed) -> (CodexLimitsSource, FakeFetcher) {
        let fetcher = FakeFetcher(answer)
        return (CodexLimitsSource(root: root, watcher: watcher, fetcher: fetcher, clock: { [now] in now.value }), fetcher)
    }

    private func writeSession(_ percent: Double, at time: String) throws -> URL {
        let folder = root.appending(path: "2026/10/15")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "rollout-a.jsonl")
        try Data((CodexRateLimitsTests.line(primary: (percent, 10080, 1_792_581_359), at: time) + "\n").utf8).write(to: url)
        return url
    }

    private func settle(_ source: CodexLimitsSource) async {
        while source.isFetching {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func startReadsTheNewestFile() async throws {
        _ = try writeSession(3, at: "2026-10-05T11:00:00.000Z")
        let (source, _) = makeSource()
        source.start()
        await settle(source)
        #expect(source.limits?.windows.first?.usedPercent == 3)
        #expect(source.isInstalled)
    }

    @Test func aChangedFileUpdatesTheLimits() async throws {
        let (source, _) = makeSource()
        source.start()
        await settle(source)
        let changes = Box(0)
        source.onChange = { changes.value += 1 }
        let url = try writeSession(5, at: "2026-10-05T11:30:00.000Z")
        watcher.onChange?([url])
        #expect(source.limits?.windows.first?.usedPercent == 5)
        #expect(changes.value == 1)
    }

    @Test func aNewerServerAnswerWinsAndBringsResets() async throws {
        _ = try writeSession(3, at: "2026-10-05T11:00:00.000Z")
        let limits = CodexLimits(windows: [window(.sevenDay, 4)], plan: "prolite", resetCredits: 3, capturedAt: fixedNow)
        let (source, _) = makeSource(.limits(limits, version: "0.162.1"))
        source.start()
        await settle(source)
        #expect(source.limits?.windows.first?.usedPercent == 4)
        #expect(source.limits?.resetCredits == 3)
        #expect(source.version == "0.162.1")
        #expect(source.status == .ok)
        // A newer file keeps the server's free resets.
        let url = try writeSession(6, at: "2026-10-05T12:30:00.000Z")
        watcher.onChange?([url])
        #expect(source.limits?.windows.first?.usedPercent == 6)
        #expect(source.limits?.resetCredits == 3)
    }

    @Test func thePopoverAsksAtMostOnceAMinute() async {
        let (source, fetcher) = makeSource()
        source.start()
        await settle(source)
        source.popoverOpened()
        await settle(source)
        #expect(fetcher.count == 1)
        now.value = fixedNow.addingTimeInterval(61)
        source.popoverOpened()
        await settle(source)
        #expect(fetcher.count == 2)
        source.refreshNow()
        await settle(source)
        #expect(fetcher.count == 3)
    }

    @Test func anAPIKeySignInShowsNoLimits() async {
        let (source, _) = makeSource(.noLimits(version: "0.162.1"))
        source.start()
        await settle(source)
        #expect(source.limits == nil)
        #expect(source.status == .noLimits)
    }

    @Test func notInstalled() async {
        watcher.exists = false
        let (source, _) = makeSource(.notInstalled)
        source.start()
        await settle(source)
        #expect(!source.isInstalled)
        #expect(source.limits == nil)
    }

    @Test func alertsFireOnceAcrossRelaunch() async throws {
        let notch = NotchSettings(defaults: defaults)
        let settings = CodexSettings(defaults: defaults)
        _ = try writeSession(85, at: "2026-10-05T11:00:00.000Z")
        let (source, _) = makeSource()
        source.start()
        await settle(source)
        let alerts = source.takeAlerts(isEnabled: true, notch: notch, settings: settings)
        #expect(alerts.count == 1)
        #expect(alerts.first?.agent == .codex)
        #expect(LimitsText.alertAccount(alerts[0]) == "codex")
        let (again, _) = makeSource()
        again.start()
        await settle(again)
        #expect(again.takeAlerts(isEnabled: true, notch: notch, settings: CodexSettings(defaults: defaults)).isEmpty)
    }

    @Test func aDisabledCodexHasNoAlerts() async throws {
        _ = try writeSession(85, at: "2026-10-05T11:00:00.000Z")
        let (source, _) = makeSource()
        source.start()
        await settle(source)
        #expect(source.takeAlerts(isEnabled: false, notch: NotchSettings(defaults: defaults), settings: CodexSettings(defaults: defaults)).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aTimerLetsResetsBeNoticed() async {
        let source = CodexLimitsSource(root: root, watcher: watcher, fetcher: FakeFetcher(.failed), clock: { [now] in now.value }, tickInterval: .milliseconds(20))
        let ticks = Box(0)
        source.onChange = { ticks.value += 1 }
        source.start(asks: false)
        while ticks.value < 3 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        source.stop()
    }

    @Test func theSameFiguresAgainDoNotCountAsAChange() async {
        let first = CodexLimits(windows: [window(.sevenDay, 4)], plan: "prolite", resetCredits: 3, capturedAt: fixedNow)
        let (source, fetcher) = makeSource(.limits(first, version: nil))
        source.start()
        await settle(source)
        #expect(source.limitsChangedAt == fixedNow)
        var later = first
        later.capturedAt = fixedNow.addingTimeInterval(120)
        fetcher.answer = .limits(later, version: nil)
        source.refreshNow()
        await settle(source)
        #expect(source.limitsChangedAt == fixedNow)
        later.windows = [window(.sevenDay, 5)]
        later.capturedAt = fixedNow.addingTimeInterval(240)
        fetcher.answer = .limits(later, version: nil)
        source.refreshNow()
        await settle(source)
        #expect(source.limitsChangedAt == fixedNow.addingTimeInterval(240))
    }
}
