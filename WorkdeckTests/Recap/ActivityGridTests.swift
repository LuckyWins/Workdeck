import Foundation
import Testing
@testable import Workdeck

struct ActivityGridTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    private func date(_ key: String) -> Date {
        RecapCalendar.date(ofKey: key, calendar: calendar)!
    }

    private func key(_ date: Date) -> String {
        RecapCalendar.dayKey(date, calendar: calendar)
    }

    /// Tuesday 2026-10-13 at 15:00; the current week starts 2026-10-12.
    private var now: Date {
        date("2026-10-13").addingTimeInterval(15 * 3600)
    }

    private func work(_ key: String, _ seconds: Double = 3600) -> RecapDay {
        RecapDay(date: key, projects: ["Workdeck": RecapProjectDay(seconds: seconds, sessionIDs: ["s"])])
    }

    private func codexDay(_ key: String, seconds: Double) -> RecapDay {
        var day = RecapDay(date: key)
        day.updateAgent(.codex) { $0.projects["B"] = RecapProjectDay(seconds: seconds) }
        day.projectSeconds["B"] = seconds
        return day
    }

    @Test func columnsRunFromTheOldestKeptWeekToThisWeek() {
        let grid = ActivityGrid.make(days: [], agent: nil, now: now, calendar: calendar)
        #expect(grid.weeks.count == RecapStore.keptWeeks + 1)
        #expect(key(grid.weeks.first!.start) == "2026-04-13")
        #expect(key(grid.weeks.last!.start) == "2026-10-12")
        #expect(grid.weeks.allSatisfy { $0.days.count == 7 })
        #expect(grid.weeks.last!.days.map { key($0.date) } == ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18"])
        #expect(grid.weeks.last!.days.map(\.isFuture) == [false, false, true, true, true, true, true])
        #expect(grid.streak == 0)
        #expect(grid.activeDays == 0)
    }

    @Test func levelsFollowFixedThresholds() {
        #expect([0, 1, 3599, 3600, 10799, 10800, 21599, 21600, 50000].map(ActivityGrid.level(seconds:)) == [0, 1, 1, 2, 2, 3, 3, 4, 4])
    }

    @Test func allUsesMergedTimeAndAnAgentItsOwn() {
        // Claude 2h on A, Codex 2h on B, 1h of it alongside Claude: 3h of real time.
        var day = RecapDay(date: "2026-10-12", projects: ["A": RecapProjectDay(seconds: 7200, sessionIDs: ["s"])])
        day.updateAgent(.codex) { $0.projects["B"] = RecapProjectDay(seconds: 7200, sessionIDs: ["c"]) }
        day.projectSeconds["B"] = 3600
        func monday(_ agent: AgentKind?) -> ActivityDay {
            ActivityGrid.make(days: [day], agent: agent, now: now, calendar: calendar).weeks.last!.days[0]
        }
        #expect(monday(nil).seconds == 10800)
        #expect(monday(nil).level == 3)
        #expect(monday(.claudeCode).seconds == 7200)
        #expect(monday(.claudeCode).level == 2)
        #expect(monday(.codex).projects.map(\.name) == ["B"])
    }

    @Test func tooltipListsTheTopThreeProjectsOfTheFilter() {
        let day = RecapDay(date: "2026-10-12", projects: [
            "D": RecapProjectDay(seconds: 600), "C": RecapProjectDay(seconds: 1200),
            "B": RecapProjectDay(seconds: 1200), "A": RecapProjectDay(seconds: 3000),
            "Z": RecapProjectDay(seconds: 0, commands: 3),
        ])
        let monday = ActivityGrid.make(days: [day], agent: nil, now: now, calendar: calendar).weeks.last!.days[0]
        #expect(monday.projects.map(\.name) == ["A", "B", "C"])
        #expect(monday.projects.map(\.seconds) == [3000, 1200, 1200])
    }

    @Test func monthsLabelTheFirstColumnOfEachMonth() {
        let grid = ActivityGrid.make(days: [], agent: nil, now: now, calendar: calendar)
        #expect(grid.months.map(\.column) == [0, 3, 7, 12, 16, 21, 25])
        #expect(grid.months.map(\.name) == ["Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct"])
    }

    @Test func aFirstColumnLabelTooCloseToTheNextIsLeftOut() {
        // Week of 2026-10-26: the first column starts 2026-04-27, May starts in column 1.
        let grid = ActivityGrid.make(days: [], agent: nil, now: date("2026-10-27").addingTimeInterval(3600), calendar: calendar)
        #expect(grid.months.map(\.column) == [1, 5, 10, 14, 19, 23])
        #expect(grid.months.first?.name == "May")
    }

    @Test func streakCountsBackFromTodayOrYesterday() {
        func streak(_ keys: [String]) -> Int {
            ActivityGrid.make(days: keys.map { work($0) }, agent: nil, now: now, calendar: calendar).streak
        }
        #expect(streak(["2026-10-11", "2026-10-12", "2026-10-13"]) == 3)
        #expect(streak(["2026-10-11", "2026-10-12"]) == 2)
        #expect(streak(["2026-10-11"]) == 0)
        #expect(streak(["2026-10-09", "2026-10-10", "2026-10-12", "2026-10-13"]) == 2)
    }

    @Test func activeDaysCountDaysWithTimeInTheGrid() {
        let days = [work("2026-04-12"), work("2026-04-13"), work("2026-09-01"), RecapDay(date: "2026-10-01")]
        #expect(ActivityGrid.make(days: days, agent: nil, now: now, calendar: calendar).activeDays == 2)
    }

    @Test func streakAndActiveDaysFollowTheFilter() {
        let days = [codexDay("2026-10-13", seconds: 600)]
        #expect(ActivityGrid.make(days: days, agent: .codex, now: now, calendar: calendar).streak == 1)
        #expect(ActivityGrid.make(days: days, agent: .claudeCode, now: now, calendar: calendar).streak == 0)
        #expect(ActivityGrid.make(days: days, agent: .claudeCode, now: now, calendar: calendar).activeDays == 0)
    }

    @Test func daysStayWholeAcrossDaylightSavingChanges() {
        // Summer time ends in Berlin on Sunday 2026-10-25.
        let grid = ActivityGrid.make(days: [], agent: nil, now: date("2026-10-27").addingTimeInterval(3600), calendar: calendar)
        let week = grid.weeks[grid.weeks.count - 2]
        #expect(week.days.map { key($0.date) } == ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25"])
        #expect(key(grid.weeks.last!.start) == "2026-10-26")
    }

    @Test func aDayRecordedAfterTodayIsIgnored() {
        let grid = ActivityGrid.make(days: [work("2026-10-13"), work("2026-10-15")], agent: nil, now: now, calendar: calendar)
        let thursday = grid.weeks.last!.days[3]
        #expect(thursday.isFuture)
        #expect(thursday.level == 0)
        #expect(thursday.seconds == 0)
        #expect(thursday.projects.isEmpty)
        #expect(grid.activeDays == 1)
        #expect(grid.streak == 1)
    }
}
