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
}
