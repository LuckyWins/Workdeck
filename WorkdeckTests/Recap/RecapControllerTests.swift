import Foundation
import Testing
@testable import Workdeck

@MainActor
struct RecapControllerTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    let directory = makeTemporaryDirectory()
    let presenter = FakePresenter()
    let activity = FakeActivity()
    let settings = RecapSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)
    let notch = NotchSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)
    let held = HeldSources()
    /// A Monday morning; last week ran 2026-10-05 to 2026-10-11.
    var monday: Date { RecapCalendar.date(ofKey: "2026-10-12", calendar: calendar)!.addingTimeInterval(9 * 3600) }
    var store: RecapStore { RecapStore(url: directory.appending(path: "recap.json")) }
    let now = Box<Date>(.distantPast)

    private func part(_ agent: AgentKind, enabled: Bool) -> AgentNotchPart {
        AgentNotchPart(
            agent: agent, isEnabled: enabled, hasSource: true, showsLimits: true, accounts: [],
            compactIndex: 0, compactLabel: nil, now: monday, sessions: [], sessionsNow: monday,
            showsAccounts: false, sessionsConnected: true, activeCount: 0
        )
    }

    private func makeController(notch hasNotch: Bool = true, enabled: [AgentKind] = AgentKind.allCases) -> (RecapController, NotchComposer) {
        if now.value == .distantPast {
            now.value = monday
        }
        let composer = NotchComposer(settings: notch, presenter: presenter, cameraHousings: { [hasNotch] }, clock: { [now] in now.value })
        for agent in AgentKind.allCases {
            let source = FakeAgentSource(part(agent, enabled: enabled.contains(agent)))
            held.sources.append(source)
            composer.register(source)
        }
        composer.start()
        let controller = RecapController(composer: composer, settings: settings, store: store, activity: activity, calendar: calendar, clock: { [now] in now.value })
        return (controller, composer)
    }

    private func source(_ agent: AgentKind) -> FakeAgentSource {
        held.sources.first { $0.agent == agent }!
    }

    private func busy(_ id: String, _ project: String, agent: AgentKind) -> ClaudeSession {
        var session = ClaudeSession(id: id, cwd: "/p/\(project)", status: .working, since: monday, lastEventAt: monday, turn: TurnEdits(startedAt: monday))
        session.agent = agent
        return session
    }

    private func saveLastWeek(seconds: Double) throws {
        try store.save([RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: seconds, sessionIDs: ["s"])])], now: monday, calendar: calendar)
    }

    @Test func launchShowsLastWeeksRecap() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController()
        controller.start()
        let shown = try #require(presenter.recaps.last ?? nil)
        #expect(shown.seconds == 3600)
        #expect(RecapCalendar.dayKey(shown.weekStart, calendar: calendar) == "2026-10-05")
    }

    @Test func aQuietWeekIsSkippedSilently() throws {
        try saveLastWeek(seconds: 600)
        let (controller, _) = makeController()
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.isEmpty)
        #expect(settings.dismissedWeek == "2026-10-05")
    }

    @Test func theRecapShowsWhileAnyAgentIsOn() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController(enabled: [.codex])
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.count == 1)
    }

    @Test func noRecapWhileEveryAgentIsOff() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController(enabled: [])
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.isEmpty)
        #expect(settings.dismissedWeek == nil)
    }

    @Test func gotItDismissesUntilNextWeek() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController()
        controller.start()
        presenter.recapDismissAction?()
        #expect(presenter.recaps.last == .some(nil))
        #expect(settings.dismissedWeek == "2026-10-05")
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.compactMap { $0 }.count == 1)
    }

    @Test func anUnlockShowsTheRecapWhenLaunchCouldNot() throws {
        try saveLastWeek(seconds: 3600)
        notch.notchlessDisplay = .menuBarText
        let (controller, _) = makeController(notch: false)
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.isEmpty)
        notch.notchlessDisplay = .virtualNotch
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.compactMap { $0 }.count == 1)
    }

    @Test func theRecapKeepsAWhenActiveNotchVisible() throws {
        try saveLastWeek(seconds: 3600)
        notch.mode = .whenActive
        let (controller, composer) = makeController()
        controller.start()
        #expect(composer.state.display != .hidden)
        presenter.recapDismissAction?()
        #expect(composer.state.display == .hidden)
    }

    @Test func everyAgentIsRecordedAndSaved() throws {
        let (controller, composer) = makeController()
        source(.claudeCode).recapSample = AgentRecapSample(agent: .claudeCode, sessions: [busy("a", "Workdeck", agent: .claudeCode)], isConnected: true)
        source(.codex).recapSample = AgentRecapSample(agent: .codex, sessions: [busy("c", "docs", agent: .codex)], isConnected: true)
        controller.start()
        now.value = monday.addingTimeInterval(60)
        composer.refresh()
        controller.save()
        let day = try #require(store.load(now: monday, calendar: calendar).first { $0.date == "2026-10-12" })
        #expect(day.projectSeconds == ["Workdeck": 30, "docs": 30])
        #expect(day.agentDay(.claudeCode)?.projects["Workdeck"]?.seconds == 60)
        #expect(day.agentDay(.codex)?.projects["docs"]?.seconds == 60)
    }

    @Test func aRecapLeftOpenIsReplacedByTheNextWeeks() throws {
        try store.save([
            RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["s"])]),
            RecapDay(date: "2026-10-14", projects: ["Workdeck": RecapProjectDay(seconds: 7200, sessionIDs: ["s"])]),
        ], now: monday, calendar: calendar)
        let (controller, _) = makeController()
        controller.start()
        #expect(presenter.recaps.last??.seconds == 3600)
        now.value = monday.addingTimeInterval(7 * 86_400)
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.last??.seconds == 7200)
    }

    @Test func detailsDismissesTheRecapAndShowsItsWeek() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController()
        let opened = Box(0)
        controller.onOpenStatistics = { opened.value += 1 }
        controller.start()
        presenter.recapDetailsAction?()
        #expect(presenter.recaps.last == .some(nil))
        #expect(settings.dismissedWeek == "2026-10-05")
        #expect(RecapCalendar.dayKey(controller.statistics.weekStart, calendar: calendar) == "2026-10-05")
        #expect(controller.statistics.summary.seconds == 3600)
        #expect(opened.value == 1)
    }

    @Test func statisticsReadTheRecordedDays() throws {
        try store.save([RecapDay(date: "2026-10-12", projects: ["Workdeck": RecapProjectDay(seconds: 600, sessionIDs: ["s"])])], now: monday, calendar: calendar)
        let (controller, _) = makeController()
        controller.start()
        controller.openStatistics(week: nil)
        #expect(controller.statistics.isCurrentWeek)
        #expect(controller.statistics.summary.seconds == 600)
        #expect(controller.statistics.thresholds == notch.thresholds)
    }

    @Test func statisticsKnowWhetherAnyHooksAreConnected() {
        let (controller, composer) = makeController()
        controller.start()
        #expect(!controller.statistics.isHooksConnected)
        source(.codex).recapSample = AgentRecapSample(agent: .codex, isConnected: true)
        composer.refresh()
        #expect(controller.statistics.isHooksConnected)
    }

    @Test func theDemoCardCountsDownItsTenSeconds() {
        let (controller, _) = makeController()
        controller.start()
        controller.demoDidStart()
        controller.demoTick(elapsed: 50, previous: 49)
        #expect(presenter.recaps.last??.isWorthShowing == true)
        #expect(presenter.recapDurations.last == .some(.seconds(10)))
        controller.demoDidStop()
        #expect(presenter.recaps.last == .some(nil))
    }

    @Test func theDemoLeavesTheRecapHistoryAndSettingsAlone() throws {
        let (controller, _) = makeController()
        controller.start()
        let dismissed = settings.dismissedWeek
        controller.demoDidStart()
        controller.demoTick(elapsed: 50, previous: 49)
        presenter.recapDismissAction?()
        #expect(presenter.recaps.last == .some(nil))
        #expect(settings.dismissedWeek == dismissed)
        controller.demoDidStop()
        controller.save()
        let saved = store.load(now: monday, calendar: calendar)
        #expect(!saved.contains { $0.projects["orbit-app"] != nil || $0.projects["docs-site"] != nil })
    }

    @Test func aRealRecapWaitsForTheStop() throws {
        try saveLastWeek(seconds: 3600)
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
    }

    @Test func aCollapsedRealRecapComesBackAsItsMark() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController()
        controller.start()
        presenter.recapExpanded = false
        controller.demoDidStart()
        controller.demoDidStop()
        #expect(presenter.recaps.last??.seconds == 3600)
        #expect(presenter.recapDurations.last == .some(.zero))
    }

    @Test func anExpandedRealRecapExpandsAgain() throws {
        try saveLastWeek(seconds: 3600)
        let (controller, _) = makeController()
        controller.start()
        presenter.recapExpanded = true
        controller.demoDidStart()
        controller.demoDidStop()
        #expect(presenter.recapDurations.last == .some(nil))
    }

    @Test func realSessionsAreRecordedDuringTheDemo() throws {
        let (controller, composer) = makeController()
        source(.claudeCode).recapSample = AgentRecapSample(agent: .claudeCode, sessions: [busy("a", "Workdeck", agent: .claudeCode)], isConnected: true)
        controller.start()
        controller.demoDidStart()
        now.value = monday.addingTimeInterval(30)
        composer.refresh()
        controller.save()
        let saved = store.load(now: monday, calendar: calendar)
        #expect(saved.contains { $0.projects["Workdeck"]?.sessionIDs.contains("a") == true })
        #expect(!saved.contains { $0.projects["orbit-app"] != nil })
    }

    @Test func statisticsFollowTheDemo() {
        let (controller, _) = makeController()
        controller.start()
        controller.statistics.isVisible = true
        controller.openStatistics(week: calendar.date(byAdding: .weekOfYear, value: -1, to: monday))
        #expect(controller.statistics.summary.seconds == 0)
        controller.demoDidStart()
        #expect(controller.statistics.summary.seconds > 0)
        #expect(controller.statistics.isHooksConnected)
        controller.demoDidStop()
        #expect(controller.statistics.summary.seconds == 0)
    }

    @Test func detailsOnTheDemoRecapOpensItsWeek() {
        let (controller, _) = makeController()
        let opened = Box(0)
        controller.onOpenStatistics = { opened.value += 1 }
        controller.start()
        let dismissed = settings.dismissedWeek
        controller.demoDidStart()
        controller.demoTick(elapsed: 50, previous: 49)
        presenter.recapDetailsAction?()
        #expect(opened.value == 1)
        #expect(RecapCalendar.dayKey(controller.statistics.weekStart, calendar: calendar) == "2026-10-05")
        #expect(settings.dismissedWeek == dismissed)
    }

    @Test func openingStatisticsShowsEveryAgent() {
        let (controller, _) = makeController()
        controller.start()
        controller.statistics.setAgent(.codex)
        controller.openStatistics(week: nil)
        #expect(controller.statistics.agent == nil)
    }

    @Test func aRecapLeftOpenGivesWayToAQuietWeek() throws {
        // The card was never dismissed; the week after it has too little work for a card of its own.
        try store.save([
            RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["s"])]),
            RecapDay(date: "2026-10-14", projects: ["Workdeck": RecapProjectDay(seconds: 300, sessionIDs: ["s"])]),
        ], now: monday, calendar: calendar)
        notch.mode = .whenActive
        let (controller, composer) = makeController()
        controller.start()
        #expect(presenter.recaps.last??.seconds == 3600)
        now.value = monday.addingTimeInterval(7 * 86_400)
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.last == .some(nil))
        #expect(composer.state.display == .hidden)
    }
}

/// A value the tests change while closures read it.
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
