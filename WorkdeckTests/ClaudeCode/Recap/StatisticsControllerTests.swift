import Foundation
import Testing
@testable import Workdeck

@MainActor
struct StatisticsControllerTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)
    let now = Box<Date>(.distantPast)

    private func date(_ key: String) -> Date {
        RecapCalendar.date(ofKey: key, calendar: calendar)!
    }

    private func key(_ date: Date) -> String {
        RecapCalendar.dayKey(date, calendar: calendar)
    }

    /// Tuesday 2026-10-13 at 15:00; the current week starts 2026-10-12.
    private func makeController(days: [RecapDay] = []) -> StatisticsController {
        now.value = date("2026-10-13").addingTimeInterval(15 * 3600)
        let controller = StatisticsController(calendar: calendar) { [now] in now.value }
        controller.isVisible = true
        controller.update(days: days, isHooksConnected: true, thresholds: [80, 95])
        return controller
    }

    private func work(_ key: String, _ seconds: Double = 3600) -> RecapDay {
        RecapDay(date: key, projects: ["Workdeck": RecapProjectDay(seconds: seconds, sessionIDs: ["s"])])
    }

    @Test func opensOnTheCurrentWeekWithNothingToGoBackTo() {
        let controller = makeController()
        #expect(key(controller.weekStart) == "2026-10-12")
        #expect(controller.isCurrentWeek)
        #expect(!controller.canGoBack)
        #expect(!controller.canGoForward)
    }

    @Test func goesBackToTheOldestWeekWithDataAndForwardAgain() {
        let controller = makeController(days: [work("2026-09-23"), work("2026-10-13")])
        controller.goBack()
        controller.goBack()
        controller.goBack()
        #expect(key(controller.weekStart) == "2026-09-21")
        #expect(controller.summary.seconds == 3600)
        #expect(!controller.canGoBack)
        controller.goBack()
        #expect(key(controller.weekStart) == "2026-09-21")
        #expect(controller.canGoForward)
        controller.goForward()
        #expect(key(controller.weekStart) == "2026-09-28")
        #expect(controller.summary.seconds == 0)
        controller.showCurrentWeek()
        #expect(controller.isCurrentWeek)
        #expect(!controller.canGoForward)
    }

    @Test func neverGoesBackMoreThanTwelveWeeks() {
        let controller = makeController(days: [work("2026-05-04")])
        for _ in 0..<20 {
            controller.goBack()
        }
        #expect(key(controller.weekStart) == "2026-07-20")
        #expect(!controller.canGoBack)
    }

    @Test func showsAWeekGivenByAnyDayInIt() {
        let controller = makeController(days: [work("2026-10-07")])
        controller.show(week: date("2026-10-09"))
        #expect(key(controller.weekStart) == "2026-10-05")
        #expect(!controller.isCurrentWeek)
        #expect(controller.summary.seconds == 3600)
    }

    @Test func theCurrentWeekUpdatesLive() {
        let controller = makeController(days: [work("2026-10-12")])
        #expect(controller.summary.seconds == 3600)
        controller.update(days: [work("2026-10-12"), work("2026-10-13", 1800)], isHooksConnected: false, thresholds: [70, 90])
        #expect(controller.summary.seconds == 5400)
        #expect(controller.pace.elapsedDays == 2)
        #expect(!controller.isHooksConnected)
        #expect(controller.thresholds == [70, 90])
    }

    @Test func thisWeekFollowsTheNewWeek() {
        let controller = makeController()
        now.value = date("2026-10-19").addingTimeInterval(9 * 3600)
        controller.update(days: [], isHooksConnected: true, thresholds: [80, 95])
        #expect(key(controller.weekStart) == "2026-10-19")
        #expect(controller.isCurrentWeek)
    }

    @Test func aPastWeekStaysWhenTheWeekTurns() {
        let controller = makeController(days: [work("2026-10-07")])
        controller.show(week: date("2026-10-05"))
        now.value = date("2026-10-19").addingTimeInterval(9 * 3600)
        controller.update(days: [work("2026-10-07")], isHooksConnected: true, thresholds: [80, 95])
        #expect(key(controller.weekStart) == "2026-10-05")
        #expect(controller.canGoForward)
    }

    @Test func anUnchangedUpdateDoesNotRepublish() {
        let controller = makeController(days: [work("2026-10-12")])
        let count = controller.publishCount
        controller.update(days: [work("2026-10-12")], isHooksConnected: true, thresholds: [80, 95])
        #expect(controller.publishCount == count)
        // The clock moves on every hook event; within the same day nothing the window shows changes.
        now.value = now.value.addingTimeInterval(120)
        controller.update(days: [work("2026-10-12")], isHooksConnected: true, thresholds: [80, 95])
        #expect(controller.publishCount == count)
    }

    @Test func aClosedWindowRebuildsWhenItOpens() {
        let controller = makeController(days: [work("2026-10-12")])
        controller.isVisible = false
        let count = controller.publishCount
        controller.update(days: [work("2026-10-12"), work("2026-10-13")], isHooksConnected: true, thresholds: [80, 95])
        #expect(controller.publishCount == count)
        #expect(controller.summary.seconds == 3600)
        controller.isVisible = true
        #expect(controller.summary.seconds == 7200)
    }

    @Test func todayMovesAtMidnight() {
        let controller = makeController()
        #expect(key(controller.today) == "2026-10-13")
        now.value = date("2026-10-14").addingTimeInterval(60)
        controller.update(days: [], isHooksConnected: true, thresholds: [80, 95])
        #expect(key(controller.today) == "2026-10-14")
    }
}
