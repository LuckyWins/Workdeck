import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClaudeCodeDemoControllerTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    let directory = makeTemporaryDirectory()
    let presenter = FakePresenter()
    let connector = FakeConnector()
    let activity = FakeActivity()
    let hooksConnector = FakeHooksConnector()
    let liveness = FakeLiveness()
    let settings = ClaudeCodeSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)
    /// A Monday morning; last week ran 2026-10-05 to 2026-10-11.
    var monday: Date { RecapCalendar.date(ofKey: "2026-10-12", calendar: calendar)!.addingTimeInterval(9 * 3600) }
    var recapStore: RecapStore { RecapStore(url: directory.appending(path: "recap.json")) }
    var usageURL: URL { directory.appending(path: "claude-usage.json") }

    private func makeController(now: Date? = nil) -> (ClaudeCodeController, ClaudeUsageStore) {
        connector.status = .connected
        let now = now ?? monday
        let usage = ClaudeUsageStore(fileURL: usageURL) { now }
        let limits = ClaudeLimitsController(settings: settings, store: usage, connector: connector, poller: FakePoller(), activity: activity)
        let sessions = ClaudeSessionsController(
            settings: settings,
            store: ClaudeSessionStore(directory: directory.appending(path: "sessions"), liveness: liveness) { now },
            hooksConnector: hooksConnector,
            activator: FakeActivator(),
            sleepPreventer: FakeSleepPreventer(),
            frontmostBundleID: { nil }
        )
        let controller = ClaudeCodeController(
            settings: settings, limits: limits, sessions: sessions, presenter: presenter,
            cameraHousings: { [true] }, clock: { now },
            recapStore: recapStore, calendar: calendar
        )
        return (controller, usage)
    }

    private func writeUsage(fiveHour: Double) throws {
        let snapshot = UsageSnapshot(capturedAt: monday, fiveHour: UsageWindow(kind: .fiveHour, usedPercent: fiveHour, resetsAt: monday.addingTimeInterval(3600)), sevenDay: nil)
        try UsageSnapshotFile.write(snapshot, to: usageURL)
    }

    @Test func theDemoShowsTheScriptEvenWhenDisabled() throws {
        settings.isEnabled = false
        let (controller, _) = makeController()
        controller.start()
        controller.demoDidStart()
        controller.demoTick(elapsed: 12, previous: 11)
        let shown = try #require(presenter.shown.last)
        guard case .notch = shown.display else {
            Issue.record("Expected the notch, got \(shown.display)")
            return
        }
        #expect(shown.accounts.map(\.name) == ["main", "personal"])
        #expect(shown.accounts.map(\.plan) == ["Max 5x", "Pro"])
        #expect(shown.sessions.rows.map(\.projectName) == ["orbit-app", "api-server"])
        #expect(shown.sessions.rows.first?.agents.map(\.type) == ["Explore"])
    }

    @Test func scriptEventsReachThePresenter() {
        settings.isEnabled = true
        let (controller, _) = makeController()
        controller.start()
        controller.demoDidStart()
        controller.demoTick(elapsed: 0, previous: nil)
        #expect(presenter.expansions == [.seconds(6)])
        controller.demoTick(elapsed: 20, previous: 19)
        #expect(presenter.alerts == [.sessionNeedsYou(project: "api-server")])
        controller.demoTick(elapsed: 50, previous: 49)
        #expect(presenter.recaps.last??.isWorthShowing == true)
        controller.demoDidStop()
        #expect(presenter.recaps.last == .some(nil))
        #expect(presenter.expansions.count == 1)
    }

    @Test func theDemoRecapCountsDownItsTenSeconds() {
        settings.isEnabled = true
        let (controller, _) = makeController()
        controller.start()
        controller.demoDidStart()
        controller.demoTick(elapsed: 50, previous: 49)
        #expect(presenter.recapDurations.last == .some(.seconds(10)))
    }

    @Test func startAndStopClearTheOtherSidesAlerts() {
        settings.isEnabled = true
        let (controller, _) = makeController()
        controller.start()
        controller.demoDidStart()
        #expect(presenter.clears == 1)
        controller.demoTick(elapsed: 20, previous: 19)
        controller.demoDidStop()
        #expect(presenter.clears == 2)
    }

    @Test func realAlertsAreDropped() throws {
        settings.isEnabled = true
        try writeUsage(fiveHour: 40)
        let (controller, usage) = makeController()
        controller.start()
        controller.demoDidStart()
        try writeUsage(fiveHour: 85)
        usage.reload()
        controller.sessions.onAlerts?([.sessionNeedsYou(project: "real")])
        controller.demoDidStop()
        usage.reload()
        #expect(!presenter.alerts.contains { if case .threshold(_, 80, _, _) = $0 { true } else { false } })
        #expect(!presenter.alerts.contains(.sessionNeedsYou(project: "real")))
        // The pipeline itself works: the next threshold after the demo shows.
        try writeUsage(fiveHour: 97)
        usage.reload()
        #expect(presenter.alerts.contains { if case .threshold(_, 95, _, _) = $0 { true } else { false } })
    }

    @Test func clicksDoNothingDuringTheDemo() {
        settings.isEnabled = true
        let (controller, _) = makeController()
        let opened = Box(0)
        controller.onOpenChats = { _ in opened.value += 1 }
        controller.start()
        controller.demoDidStart()
        presenter.chatsAction?("main")
        #expect(opened.value == 0)
        controller.demoDidStop()
        presenter.chatsAction?("main")
        #expect(opened.value == 1)
    }

    @Test func theDemoLeavesTheRecapHistoryAndSettingsAlone() throws {
        settings.isEnabled = true
        let (controller, _) = makeController()
        controller.start()
        // The start skips the quiet real week; the demo must not change that.
        let dismissed = settings.dismissedRecapWeek
        controller.demoDidStart()
        controller.demoTick(elapsed: 12, previous: 11)
        controller.demoTick(elapsed: 50, previous: 49)
        presenter.recapDismissAction?()
        #expect(presenter.recaps.last == .some(nil))
        #expect(settings.dismissedRecapWeek == dismissed)
        controller.saveRecap()
        let saved = recapStore.load(now: monday, calendar: calendar)
        #expect(!saved.contains { $0.projects["orbit-app"] != nil })
    }

    @Test func aRealRecapWaitsForTheStop() throws {
        settings.isEnabled = true
        try recapStore.save([RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["s"])])], now: monday, calendar: calendar)
        let (controller, _) = makeController()
        controller.start()
        #expect(presenter.recaps.last??.seconds == 3600)
        controller.demoDidStart()
        #expect(presenter.recaps.last == .some(nil))
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.last == .some(nil))
        controller.demoDidStop()
        #expect(presenter.recaps.last??.seconds == 3600)
        #expect(presenter.shown.last?.accounts.map(\.name) == ["main"])
    }

    @Test func aCollapsedRealRecapComesBackAsItsMark() throws {
        settings.isEnabled = true
        try recapStore.save([RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["s"])])], now: monday, calendar: calendar)
        let (controller, _) = makeController()
        controller.start()
        presenter.recapExpanded = false
        controller.demoDidStart()
        controller.demoDidStop()
        #expect(presenter.recaps.last??.seconds == 3600)
        #expect(presenter.recapDurations.last == .some(.zero))
    }

    @Test func anExpandedRealRecapExpandsAgain() throws {
        settings.isEnabled = true
        try recapStore.save([RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["s"])])], now: monday, calendar: calendar)
        let (controller, _) = makeController()
        controller.start()
        presenter.recapExpanded = true
        controller.demoDidStart()
        controller.demoDidStop()
        #expect(presenter.recapDurations.last == .some(nil))
    }

    @Test func realSessionsAreRecordedDuringTheDemo() {
        settings.isEnabled = true
        hooksConnector.status = .connected
        let sessions = directory.appending(path: "sessions")
        writeSessionEvent(hookEvent(.sessionStart, at: 0) { $0.pid = 42; $0.cwd = "/p/Workdeck" }, to: sessions)
        writeSessionEvent(hookEvent(.userPromptSubmit, at: 1), to: sessions)
        liveness.startTimes[42] = fixedNow.addingTimeInterval(-60)
        let (controller, _) = makeController(now: fixedNow.addingTimeInterval(2))
        controller.start()
        controller.demoDidStart()
        controller.demoTick(elapsed: 12, previous: 11)
        controller.saveRecap()
        let saved = recapStore.load(now: fixedNow, calendar: calendar)
        #expect(saved.contains { $0.projects["Workdeck"]?.sessionIDs.contains("s1") == true })
        #expect(!saved.contains { $0.projects["orbit-app"] != nil })
    }

    @Test func statisticsFollowTheDemo() {
        settings.isEnabled = true
        let (controller, _) = makeController()
        controller.start()
        controller.statistics.isVisible = true
        controller.openStatistics(week: calendar.date(byAdding: .weekOfYear, value: -1, to: monday))
        #expect(controller.statistics.summary.seconds == 0)
        controller.demoDidStart()
        #expect(controller.statistics.summary.seconds > 0)
        controller.demoDidStop()
        #expect(controller.statistics.summary.seconds == 0)
    }

    @Test func detailsOnTheDemoRecapOpensItsWeek() {
        settings.isEnabled = true
        let (controller, _) = makeController()
        let opened = Box(0)
        controller.onOpenStatistics = { opened.value += 1 }
        controller.start()
        let dismissed = settings.dismissedRecapWeek
        controller.demoDidStart()
        controller.demoTick(elapsed: 50, previous: 49)
        presenter.recapDetailsAction?()
        #expect(opened.value == 1)
        #expect(RecapCalendar.dayKey(controller.statistics.weekStart, calendar: calendar) == "2026-10-05")
        #expect(settings.dismissedRecapWeek == dismissed)
    }
}
