import Foundation
import Testing
@testable import Workdeck

struct WeeklyRecapTests {
    let calendar = RecapCalendar.calendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    private func date(_ text: String) -> Date {
        RecapCalendar.date(ofKey: text, calendar: calendar)!
    }

    private func day(_ key: String, _ projects: [String: RecapProjectDay], longest: RecapStretch? = nil, accounts: [String: RecapAccountDay] = [:]) -> RecapDay {
        RecapDay(date: key, projects: projects, longest: longest, accounts: accounts)
    }

    @Test func weeksRunMondayToSundayWhateverTheLocale() {
        // 2026-10-11 is a Sunday, 2026-10-12 a Monday.
        #expect(RecapCalendar.dayKey(RecapCalendar.weekStart(of: date("2026-10-11"), calendar: calendar), calendar: calendar) == "2026-10-05")
        #expect(RecapCalendar.dayKey(RecapCalendar.weekStart(of: date("2026-10-12"), calendar: calendar), calendar: calendar) == "2026-10-12")
        #expect(RecapCalendar.dayKey(RecapCalendar.weekStart(of: date("2026-10-12").addingTimeInterval(-1), calendar: calendar), calendar: calendar) == "2026-10-05")
    }

    @Test func dayKeysRoundTrip() {
        #expect(RecapCalendar.dayKey(date("2026-03-29"), calendar: calendar) == "2026-03-29")
        #expect(RecapCalendar.date(ofKey: "nonsense", calendar: calendar) == nil)
    }

    @Test func aWeekSumsItsDaysOnly() {
        let monday = date("2026-10-05")
        let days = [
            day("2026-10-04", ["old": RecapProjectDay(seconds: 9999, sessionIDs: ["x"])]),
            day("2026-10-05", [
                "Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["a"], files: ["A.swift", "B.swift"], added: 10, removed: 2, commands: 5, agents: 1),
                "vitastir": RecapProjectDay(seconds: 1800, sessionIDs: ["b"], files: ["C.swift"], added: 1, removed: 0, commands: 2, agents: 0),
            ], longest: RecapStretch(project: "Workdeck", seconds: 3000)),
            day("2026-10-08", [
                "Workdeck": RecapProjectDay(seconds: 7200, sessionIDs: ["a", "c"], files: ["A.swift"], added: 5, removed: 5, commands: 1, agents: 2),
                "pokemon": RecapProjectDay(seconds: 600, sessionIDs: ["d"]),
                "tiny": RecapProjectDay(seconds: 60, sessionIDs: ["e"]),
            ], longest: RecapStretch(project: "Workdeck", seconds: 5400)),
            day("2026-10-12", ["next": RecapProjectDay(seconds: 9999, sessionIDs: ["y"])]),
        ]
        let summary = WeeklyRecap.summary(days: days, weekStart: monday, calendar: calendar)
        #expect(summary.seconds == 13260)
        #expect(summary.sessions == 5)
        // Distinct files per project: Workdeck A, B; vitastir C.
        #expect(summary.files == 3)
        #expect(summary.added == 16)
        #expect(summary.removed == 7)
        #expect(summary.commands == 8)
        #expect(summary.agents == 3)
        #expect(summary.days[3].seconds == 7860)
        #expect(summary.longest == RecapStretch(project: "Workdeck", seconds: 5400))
        #expect(summary.topProjects == [RecapProjectTime(name: "Workdeck", seconds: 10800), RecapProjectTime(name: "vitastir", seconds: 1800), RecapProjectTime(name: "pokemon", seconds: 600)])
        #expect(summary.isWorthShowing)
    }

    @Test func hitsAreCountedOncePerWindowAcrossDays() {
        let window = date("2026-10-06").addingTimeInterval(3600)
        let days = [
            day("2026-10-05", [:], accounts: ["main": RecapAccountDay(hitWindows: [window], weeklyPeak: 40)]),
            day("2026-10-06", [:], accounts: ["main": RecapAccountDay(hitWindows: [window, window.addingTimeInterval(18000)], weeklyPeak: 61), "personal": RecapAccountDay(weeklyPeak: 12)]),
        ]
        let summary = WeeklyRecap.summary(days: days, weekStart: date("2026-10-05"), calendar: calendar)
        #expect(summary.accounts == [RecapAccountSummary(name: "main", hits: 2, weeklyPeak: 61), RecapAccountSummary(name: "personal", hits: 0, weeklyPeak: 12)])
    }

    @Test func aQuietWeekIsNotWorthShowing() {
        let days = [day("2026-10-05", ["a": RecapProjectDay(seconds: 899, sessionIDs: ["s"])])]
        #expect(!WeeklyRecap.summary(days: days, weekStart: date("2026-10-05"), calendar: calendar).isWorthShowing)
        #expect(WeeklyRecap.summary(days: [], weekStart: date("2026-10-05"), calendar: calendar).days.allSatisfy { $0.seconds == 0 })
    }

    @Test func daysWrittenWithFewerFieldsStillLoad() throws {
        // A later version adds fields; an older file must not be set aside as corrupt.
        let json = #"{"date":"2026-10-05","projects":{"Workdeck":{"seconds":60}}}"#
        let day = try JSONDecoder().decode(RecapDay.self, from: Data(json.utf8))
        #expect(day.projects["Workdeck"] == RecapProjectDay(seconds: 60))
        #expect(day.accounts.isEmpty)
        #expect(day.longest == nil)
    }

    @Test func aSundayFirstLocaleStillStartsOnMonday() {
        var sundayFirst = calendar
        sundayFirst.locale = Locale(identifier: "en_US")
        #expect(RecapCalendar.dayKey(RecapCalendar.weekStart(of: date("2026-10-11"), calendar: sundayFirst), calendar: sundayFirst) == "2026-10-05")
    }

    @Test func daysAreSplitByProjectMondayFirst() {
        let monday = date("2026-10-05")
        let days = [
            day("2026-10-05", ["Workdeck": RecapProjectDay(seconds: 3600), "vitastir": RecapProjectDay(seconds: 1800)]),
            day("2026-10-08", ["Workdeck": RecapProjectDay(seconds: 600)]),
        ]
        let summary = WeeklyRecap.summary(days: days, weekStart: monday, calendar: calendar)
        #expect(summary.days.count == 7)
        #expect(summary.days.map { RecapCalendar.dayKey($0.date, calendar: calendar) } == ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11"])
        #expect(summary.days[0].projects == ["Workdeck": 3600, "vitastir": 1800])
        #expect(summary.days[0].seconds == 5400)
        #expect(summary.days[1].projects.isEmpty)
        #expect(summary.days[3].projects == ["Workdeck": 600])
    }

    @Test func everyProjectIsListedWithItsWork() {
        let monday = date("2026-10-05")
        let days = [
            day("2026-10-05", [
                "Workdeck": RecapProjectDay(seconds: 3600, sessionIDs: ["a"], files: ["A.swift", "B.swift"], added: 10, removed: 2),
                "b": RecapProjectDay(seconds: 60, sessionIDs: ["x"]),
                "a": RecapProjectDay(seconds: 60, sessionIDs: ["y"]),
                "vitastir": RecapProjectDay(seconds: 1800, sessionIDs: ["b"], files: ["C.swift"], added: 1),
            ]),
            day("2026-10-06", ["Workdeck": RecapProjectDay(seconds: 600, sessionIDs: ["a", "c"], files: ["A.swift"], added: 5, removed: 5)]),
        ]
        let summary = WeeklyRecap.summary(days: days, weekStart: monday, calendar: calendar)
        #expect(summary.projects == [
            RecapProjectSummary(name: "Workdeck", seconds: 4200, sessions: 2, files: 2, added: 15, removed: 7),
            RecapProjectSummary(name: "vitastir", seconds: 1800, sessions: 1, files: 1, added: 1, removed: 0),
            RecapProjectSummary(name: "a", seconds: 60, sessions: 1, files: 0, added: 0, removed: 0),
            RecapProjectSummary(name: "b", seconds: 60, sessions: 1, files: 0, added: 0, removed: 0),
        ])
        #expect(summary.topProjects.map(\.name) == ["Workdeck", "vitastir", "a"])
    }

    @Test func paceComparesTheSameDaysOfTheWeekBefore() {
        // Tuesday 2026-10-13 at 15:00: Monday and Tuesday against last Monday and Tuesday; last Wednesday does not count.
        let now = date("2026-10-13").addingTimeInterval(15 * 3600)
        let days = [
            day("2026-10-05", ["a": RecapProjectDay(seconds: 3600)]),
            day("2026-10-06", ["a": RecapProjectDay(seconds: 1800)]),
            day("2026-10-07", ["a": RecapProjectDay(seconds: 18000)]),
            day("2026-10-12", ["a": RecapProjectDay(seconds: 3600)]),
            day("2026-10-13", ["a": RecapProjectDay(seconds: 3600)]),
        ]
        let pace = WeeklyRecap.pace(days: days, weekStart: date("2026-10-12"), now: now, calendar: calendar)
        #expect(pace.elapsedDays == 2)
        #expect(pace.average == 3600)
        #expect(abs((pace.change ?? 0) - 1.0 / 3.0) < 0.0001)
    }

    @Test func aPastWeekAveragesOverSevenDays() {
        let days = [
            day("2026-09-29", ["a": RecapProjectDay(seconds: 7000)]),
            day("2026-10-05", ["a": RecapProjectDay(seconds: 7000)]),
            day("2026-10-11", ["a": RecapProjectDay(seconds: 7000)]),
        ]
        let pace = WeeklyRecap.pace(days: days, weekStart: date("2026-10-05"), now: date("2026-10-13"), calendar: calendar)
        #expect(pace.elapsedDays == 7)
        #expect(pace.average == 2000)
        #expect(pace.change == 1)
    }

    @Test func noComparisonWithoutEarlierTime() {
        let days = [day("2026-10-12", ["a": RecapProjectDay(seconds: 3600)])]
        let pace = WeeklyRecap.pace(days: days, weekStart: date("2026-10-12"), now: date("2026-10-12").addingTimeInterval(3600), calendar: calendar)
        #expect(pace.elapsedDays == 1)
        #expect(pace.change == nil)
    }

    @Test func anEmptyWeekHasNoPace() {
        let pace = WeeklyRecap.pace(days: [], weekStart: date("2026-10-12"), now: date("2026-10-14"), calendar: calendar)
        #expect(pace == RecapPace(elapsedDays: 3, average: 0, change: nil))
    }

    @Test func paceCountsCalendarDaysAcrossDaylightSaving() {
        // Europe/Berlin leaves summer time on Sunday 2026-10-25; that week has a 25-hour day.
        let now = date("2026-10-25").addingTimeInterval(23 * 3600)
        let pace = WeeklyRecap.pace(days: [], weekStart: date("2026-10-19"), now: now, calendar: calendar)
        #expect(pace.elapsedDays == 7)
    }

    @Test func projectsCarryTheirCommandsAndAgents() {
        let days = [
            day("2026-10-05", ["Workdeck": RecapProjectDay(seconds: 60, commands: 5, agents: 1), "vib3": RecapProjectDay(seconds: 30, commands: 2)]),
            day("2026-10-06", ["Workdeck": RecapProjectDay(seconds: 60, commands: 3, agents: 2)]),
        ]
        let summary = WeeklyRecap.summary(days: days, weekStart: date("2026-10-05"), calendar: calendar)
        #expect(summary.projects.map(\.commands) == [8, 2])
        #expect(summary.projects.map(\.agents) == [3, 0])
    }
}
