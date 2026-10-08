import Foundation
import Testing
@testable import Workdeck

private func near(_ date: Date?, _ expected: Date) -> Bool {
    guard let date else { return false }
    return abs(date.timeIntervalSince(expected)) < 0.01
}

struct UsageForecastTests {
    // A 5-hour window resetting in 1 h started 4 h ago. At 90 % the average rate is 22.5 %/h,
    // so the last 10 % takes 1600 s.
    @Test func averageRateForFiveHourWindow() {
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 90), now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1600)))
    }

    @Test func noForecastWhenTheLimitLastsUntilReset() {
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 20), now: fixedNow) == nil)
    }

    @Test func noForecastInTheFirstFifteenMinutes() {
        let young = window(.fiveHour, 50, resetsIn: 5 * 3600 - 600)
        #expect(UsageForecast.exhaustion(window: young, now: fixedNow) == nil)
    }

    // A weekly window resetting in 1 day started 6 days ago. 90 % over 6 days is 15 %/day,
    // so the last 10 % takes 16 h.
    @Test func weeklyWindow() {
        let weekly = window(.sevenDay, 90, resetsIn: 86_400)
        let result = UsageForecast.exhaustion(window: weekly, now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(16 * 3600)))
    }

    @Test func noWeeklyForecastInTheFirstSixHours() {
        let young = window(.sevenDay, 30, resetsIn: 7 * 86_400 - 3 * 3600)
        #expect(UsageForecast.exhaustion(window: young, now: fixedNow) == nil)
    }

    @Test func noForecastAtTheLimitExpiredOrUnused() {
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 100), now: fixedNow) == nil)
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 90, resetsIn: -1), now: fixedNow) == nil)
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 0), now: fixedNow) == nil)
    }
}

struct LimitsForecastTextTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    @Test func forecastText() {
        #expect(LimitsText.forecastText(fixedNow.addingTimeInterval(4 * 3600 + 40 * 60), now: fixedNow, calendar: utc) == "runs out ~16:40")
        #expect(LimitsText.forecastText(fixedNow.addingTimeInterval(2 * 86_400), now: fixedNow, calendar: utc) == "runs out ~Wed 12:00")
        // Tomorrow, less than a day away: the time alone would read as today. Later days show the weekday.
        #expect(LimitsText.forecastText(fixedNow.addingTimeInterval(23 * 3600), now: fixedNow, calendar: utc) == "runs out ~tomorrow 11:00")
    }

    @Test func resetClockText() {
        #expect(LimitsText.resetClockText(fixedNow.addingTimeInterval(6 * 3600), now: fixedNow, calendar: utc) == "resets 18:00")
        #expect(LimitsText.resetClockText(fixedNow.addingTimeInterval(13 * 3600), now: fixedNow, calendar: utc) == "resets tomorrow 01:00")
        #expect(LimitsText.resetClockText(fixedNow.addingTimeInterval(3 * 86_400 - 3 * 3600), now: fixedNow, calendar: utc) == "resets Thu 09:00")
    }
}
