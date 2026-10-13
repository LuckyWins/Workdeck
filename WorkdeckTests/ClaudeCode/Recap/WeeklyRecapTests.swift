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
        #expect(summary.busiest == RecapDayTime(date: date("2026-10-08"), seconds: 7860))
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
        #expect(WeeklyRecap.summary(days: [], weekStart: date("2026-10-05"), calendar: calendar).busiest == nil)
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

}
