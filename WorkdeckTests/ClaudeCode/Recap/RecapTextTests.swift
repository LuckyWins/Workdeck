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
}
