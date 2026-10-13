import Foundation
import Testing
@testable import Workdeck

@MainActor
struct RecapControllerTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    let directory = makeTemporaryDirectory()
    let presenter = FakePresenter()
    let connector = FakeConnector()
    let hooksConnector = FakeHooksConnector()
    let activity = FakeActivity()
    let settings = ClaudeCodeSettings(defaults: UserDefaults(suiteName: "WorkdeckTests.\(UUID().uuidString)")!)
    /// A Monday morning; last week ran 2026-10-05 to 2026-10-11.
    var monday: Date { RecapCalendar.date(ofKey: "2026-10-12", calendar: calendar)!.addingTimeInterval(9 * 3600) }
    var store: RecapStore { RecapStore(url: directory.appending(path: "recap.json")) }
    let now = Box<Date>(.distantPast)

    private func makeController(notch: Bool = true) -> ClaudeCodeController {
        settings.isEnabled = true
        connector.status = .connected
        if now.value == .distantPast {
            now.value = monday
        }
        let usage = ClaudeUsageStore(fileURL: directory.appending(path: "claude-usage.json")) { [monday] in monday }
        let limits = ClaudeLimitsController(settings: settings, store: usage, connector: connector, poller: FakePoller(), activity: activity)
        let sessions = ClaudeSessionsController(
            settings: settings,
            store: ClaudeSessionStore(directory: directory.appending(path: "sessions"), liveness: FakeLiveness()) { [monday] in monday },
            hooksConnector: hooksConnector,
            activator: FakeActivator(),
            sleepPreventer: FakeSleepPreventer(),
            frontmostBundleID: { nil }
        )
        return ClaudeCodeController(
            settings: settings, limits: limits, sessions: sessions, presenter: presenter,
            cameraHousings: { [notch] }, clock: { [now] in now.value },
            recapStore: store, calendar: calendar
        )
    }

    private func saveLastWeek(seconds: Double) throws {
        try store.save([RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: seconds, sessionIDs: ["s"])])], now: monday, calendar: calendar)
    }

    @Test func launchShowsLastWeeksRecap() throws {
        try saveLastWeek(seconds: 3600)
        let controller = makeController()
        controller.start()
        let shown = try #require(presenter.recaps.last ?? nil)
        #expect(shown.seconds == 3600)
        #expect(RecapCalendar.dayKey(shown.weekStart, calendar: calendar) == "2026-10-05")
    }

    @Test func aQuietWeekIsSkippedSilently() throws {
        try saveLastWeek(seconds: 600)
        let controller = makeController()
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.isEmpty)
        #expect(settings.dismissedRecapWeek == "2026-10-05")
    }

    @Test func gotItDismissesUntilNextWeek() throws {
        try saveLastWeek(seconds: 3600)
        let controller = makeController()
        controller.start()
        presenter.recapDismissAction?()
        #expect(presenter.recaps.last == .some(nil))
        #expect(settings.dismissedRecapWeek == "2026-10-05")
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.compactMap { $0 }.count == 1)
    }

    @Test func anUnlockShowsTheRecapWhenLaunchCouldNot() throws {
        try saveLastWeek(seconds: 3600)
        settings.notchlessDisplay = .menuBarText
        let controller = makeController(notch: false)
        controller.start()
        #expect(presenter.recaps.compactMap { $0 }.isEmpty)
        settings.notchlessDisplay = .virtualNotch
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.compactMap { $0 }.count == 1)
    }

    @Test func theRecapKeepsAWhenActiveNotchVisible() throws {
        try saveLastWeek(seconds: 3600)
        settings.mode = .whenActive
        let controller = makeController()
        controller.start()
        #expect(controller.state.display != .hidden)
        presenter.recapDismissAction?()
        #expect(controller.state.display == .hidden)
    }

    @Test func workIsRecordedAndSaved() throws {
        let controller = makeController()
        controller.start()
        controller.saveRecap()
        #expect(FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func aRecapLeftOpenIsReplacedByTheNextWeeks() throws {
        try store.save([
            RecapDay(date: "2026-10-07", projects: ["Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["s"])]),
            RecapDay(date: "2026-10-14", projects: ["Workdeck": RecapProjectDay(seconds: 7200, sessionIDs: ["s"])]),
        ], now: monday, calendar: calendar)
        let controller = makeController()
        controller.start()
        #expect(presenter.recaps.last??.seconds == 3600)
        // Got it was never clicked; a week later the new week's recap takes its place.
        now.value = monday.addingTimeInterval(7 * 86_400)
        activity.send(false)
        activity.send(true)
        #expect(presenter.recaps.last??.seconds == 7200)
    }

}

/// A value the tests change while closures read it.
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
