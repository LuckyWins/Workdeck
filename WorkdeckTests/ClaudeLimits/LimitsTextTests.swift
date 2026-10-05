import Foundation
import Testing
@testable import Workdeck

struct LimitsTextTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test(arguments: [
        (30.0, "resets in 1m"),
        (45 * 60.0, "resets in 45m"),
        (3600.0, "resets in 1h"),
        (80 * 60.0, "resets in 1h 20m"),
    ])
    func resetWithinADay(seconds: TimeInterval, expected: String) {
        #expect(LimitsText.resetText(fixedNow.addingTimeInterval(seconds), now: fixedNow, calendar: utc) == expected)
    }

    @Test func resetLaterShowsWeekdayAndTime() {
        // fixedNow is Monday 12:00 UTC; +2 days 21 h is Thursday 09:00.
        let resetsAt = fixedNow.addingTimeInterval(2 * 86_400 + 21 * 3600)
        #expect(LimitsText.resetText(resetsAt, now: fixedNow, calendar: utc) == "resets Thu 09:00")
    }

    @Test func expiredWindow() {
        #expect(LimitsText.expiredText(fixedNow.addingTimeInterval(2 * 3600), calendar: utc) == "reset at 14:00")
    }

    @Test(arguments: [
        (10.0, "Updated just now"),
        (3 * 60.0, "Updated 3 min ago"),
        (2 * 3600.0, "Updated 2 h ago — open Claude Code to refresh"),
    ])
    func age(seconds: TimeInterval, expected: String) {
        #expect(LimitsText.ageText(seconds) == expected)
    }

    @Test func alertTexts() {
        let usage = window(.fiveHour, 81, resetsIn: 2 * 3600)
        #expect(LimitsText.alertTitle(.threshold(usage, threshold: 80)) == "5-hour limit at 80%")
        #expect(LimitsText.alertSubtitle(.threshold(usage, threshold: 80), now: fixedNow, calendar: utc) == "Resets at 14:00")
        #expect(LimitsText.alertTitle(.reset(.sevenDay)) == "Weekly limit reset")
        #expect(LimitsText.alertSubtitle(.reset(.sevenDay), now: fixedNow, calendar: utc) == nil)
    }

    @Test func rowSubtitleStates() {
        #expect(LimitsText.rowSubtitle(isConnected: false, currentWindows: [], age: nil, connectedAt: nil, now: fixedNow)
            == "Not connected to Claude Code")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [], age: nil, connectedAt: fixedNow.addingTimeInterval(-3600), now: fixedNow)
            == "Waiting for data — start a Claude Code session")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [], age: nil, connectedAt: fixedNow.addingTimeInterval(-25 * 3600), now: fixedNow)
            == "Requires a Claude Pro or Max plan")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [window(.fiveHour, 42), window(.sevenDay, 18)], age: 180, connectedAt: nil, now: fixedNow)
            == "5h 42% · 7d 18% · updated 3m ago")
        #expect(LimitsText.rowSubtitle(isConnected: true, currentWindows: [window(.sevenDay, 18)], age: 5, connectedAt: nil, now: fixedNow)
            == "5h — · 7d 18% · updated just now")
    }
}
