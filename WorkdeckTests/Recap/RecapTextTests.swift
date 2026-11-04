import Foundation
import Testing
@testable import Workdeck

struct RecapTextTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    @Test(arguments: [(0.0, "<1m"), (59.0, "<1m"), (60.0, "1m"), (2520.0, "42m"), (8040.0, "2h 14m"), (32580.0, "9h 03m"), (67320.0, "18h 42m")] as [(Double, String)])
    func durations(seconds: Double, expected: String) {
        #expect(RecapText.duration(seconds) == expected)
    }

    @Test func numbersGroupThousandsWithAThinSpace() {
        #expect(RecapText.number(999) == "999")
        #expect(RecapText.number(4820) == "4\u{2009}820")
        #expect(RecapText.number(1_234_567) == "1\u{2009}234\u{2009}567")
    }

    @Test func weekRangesAndDays() {
        let monday = RecapCalendar.date(ofKey: "2026-10-05", calendar: calendar)!
        #expect(RecapText.weekRange(monday, calendar: calendar) == "Oct 5–11")
        let acrossMonths = RecapCalendar.date(ofKey: "2026-09-28", calendar: calendar)!
        #expect(RecapText.weekRange(acrossMonths, calendar: calendar) == "Sep 28–Oct 4")
        #expect(RecapText.dayName(RecapCalendar.date(ofKey: "2026-10-08", calendar: calendar)!, calendar: calendar) == "Thu")
    }

    @Test func comparisons() {
        #expect(RecapText.comparison(nil) == nil)
        #expect(RecapText.comparison(0.18) == "▲ 18% from the same days last week")
        #expect(RecapText.comparison(-0.25) == "▼ 25% from the same days last week")
        #expect(RecapText.comparison(0.004) == "about the same as the same days last week")
        #expect(RecapText.comparison(-0.0099) == "about the same as the same days last week")
        #expect(RecapText.comparison(2.5) == "▲ 250% from the same days last week")
    }

    @Test func chartAxisLabelsStayDistinct() {
        #expect(RecapText.axisHours(0) == "0")
        #expect(RecapText.axisHours(0.25) == "15m")
        #expect(RecapText.axisHours(0.5) == "30m")
        #expect(RecapText.axisHours(1) == "1h")
        #expect(RecapText.axisHours(1.5) == "1h 30m")
        #expect(RecapText.axisHours(4) == "4h")
    }

    @Test func perDayAndProjectDetails() {
        #expect(RecapText.perDay(11520) == "3h 12m a day")
        #expect(RecapText.projectDetail(RecapProjectSummary(name: "a", seconds: 1, sessions: 4, files: 31, added: 1380, removed: 290)) == "4 sessions · 31 files · +1\u{2009}380 −290")
        #expect(RecapText.projectDetail(RecapProjectSummary(name: "a", seconds: 1, sessions: 1, files: 1, added: 3, removed: 0)) == "1 session · 1 file · +3")
        #expect(RecapText.projectDetail(RecapProjectSummary(name: "a", seconds: 1, sessions: 2, files: 0, added: 0, removed: 0)) == "2 sessions")
        #expect(RecapText.sessions(1) == "1 session")
        #expect(RecapText.sessions(1200) == "1\u{2009}200 sessions")
    }

    @Test func aHoveredDaysHeader() {
        let tuesday = RecapCalendar.date(ofKey: "2026-10-13", calendar: calendar)!
        #expect(RecapText.dayDate(tuesday, calendar: calendar) == "Tue, Oct 13")
        #expect(RecapText.dayDetail(projects: 3, seconds: 3180, average: 1860) == "3 projects · 22m above the daily average")
        #expect(RecapText.dayDetail(projects: 1, seconds: 600, average: 1860) == "1 project · 21m below the daily average")
        #expect(RecapText.dayDetail(projects: 2, seconds: 1890, average: 1860) == "2 projects · about the daily average")
    }

    @Test func theSplitLineListsAgentsWithTime() {
        let parts = RecapText.agentSplit([.claudeCode: 36_300, .codex: 15_000])
        #expect(parts.map(\.agent) == [.claudeCode, .codex])
        #expect(parts.map(\.text) == ["Claude \(RecapText.duration(36_300))", "Codex \(RecapText.duration(15_000))"])
        #expect(RecapText.agentSplit([.codex: 600, .claudeCode: 0]).map(\.agent) == [.codex])
    }

    @Test func anEmptyWeekNamesTheFilteredAgent() {
        #expect(RecapText.noWork(nil) == "No coding work this week.")
        #expect(RecapText.noWork(.claudeCode) == "No Claude Code work this week.")
        #expect(RecapText.noWork(.codex) == "No Codex work this week.")
    }

    @Test func activityCopy() {
        #expect(RecapText.streak(9) == "9 day streak")
        #expect(RecapText.streak(1) == "1 day streak")
        #expect(RecapText.activeDays(67) == "67 active days")
        #expect(RecapText.activeDays(1) == "1 active day")
        #expect(RecapText.noCoding == "No coding")
        #expect(RecapText.activityLegendHelp == "Under 1h · 1–3h · 3–6h · 6h or more")
        let thursday = RecapCalendar.date(ofKey: "2026-10-29", calendar: calendar)!
        #expect(RecapText.monthName(thursday, calendar: calendar) == "Oct")
        #expect(RecapText.accessibleDay(thursday, seconds: 11520, calendar: calendar) == "Thursday, October 29, 3 hours 12 minutes")
        #expect(RecapText.accessibleDay(thursday, seconds: 3660, calendar: calendar) == "Thursday, October 29, 1 hour 1 minute")
        #expect(RecapText.accessibleDay(thursday, seconds: 7200, calendar: calendar) == "Thursday, October 29, 2 hours")
        #expect(RecapText.accessibleDay(thursday, seconds: 300, calendar: calendar) == "Thursday, October 29, 5 minutes")
        #expect(RecapText.accessibleDay(thursday, seconds: 30, calendar: calendar) == "Thursday, October 29, less than a minute")
        #expect(RecapText.accessibleDay(thursday, seconds: 0, calendar: calendar) == "Thursday, October 29, no coding")
    }

    @Test func anUpcomingDayIsReadAsUpcoming() {
        let friday = RecapCalendar.date(ofKey: "2026-10-30", calendar: calendar)!
        #expect(RecapText.accessibleDay(friday, seconds: 0, isFuture: true, calendar: calendar) == "Friday, October 30, upcoming")
    }
}
