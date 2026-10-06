import Foundation
import Testing
@testable import Workdeck

private func near(_ date: Date?, _ expected: Date) -> Bool {
    guard let date else { return false }
    return abs(date.timeIntervalSince(expected)) < 0.01
}

private func sample(_ secondsAgo: TimeInterval, _ percent: Double, resetsIn: TimeInterval = 3600) -> UsageSample {
    UsageSample(date: fixedNow.addingTimeInterval(-secondsAgo), percent: percent, resetsAt: fixedNow.addingTimeInterval(resetsIn))
}

struct UsageForecastTests {
    // A 5-hour window resetting in 1 h started 4 h ago. At 90 % the average rate is 22.5 %/h,
    // so the last 10 % takes 1600 s.
    @Test func averageRateForFiveHourWindow() {
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 90), samples: [], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1600)))
    }

    @Test func noForecastWhenTheLimitLastsUntilReset() {
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 20), samples: [], now: fixedNow) == nil)
    }

    @Test func noForecastInTheFirstFifteenMinutes() {
        let young = window(.fiveHour, 50, resetsIn: 5 * 3600 - 600)
        #expect(UsageForecast.exhaustion(window: young, samples: [], now: fixedNow) == nil)
    }

    // 40 % → 70 % in the last 30 min is 1 %/min, so the last 30 % takes 30 min; the average rate alone
    // (70 % over 4 h) would last past the reset.
    @Test func recentRateWinsForFiveHourWindow() {
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 70), samples: [sample(1800, 40)], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1800)))
    }

    @Test func idleRecentHistoryMeansNoForecast() {
        // The average rate alone would forecast 758 s.
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 95), samples: [sample(1800, 95)], now: fixedNow) == nil)
    }

    @Test func shortHistoryFallsBackToAverage() {
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 90), samples: [sample(300, 80)], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1600)))
    }

    @Test func oldSamplesAreIgnored() {
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 90), samples: [sample(7200, 10)], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1600)))
    }

    @Test func futureSamplesAreIgnored() {
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 90), samples: [sample(-60, 10)], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1600)))
    }

    @Test func otherPeriodSamplesAreIgnored() {
        let previous = sample(1800, 99, resetsIn: 3600 - 5 * 3600)
        let result = UsageForecast.exhaustion(window: window(.fiveHour, 90), samples: [previous], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(1600)))
    }

    // A weekly window resetting in 1 day started 6 days ago. 90 % over 6 days is 15 %/day,
    // so the last 10 % takes 16 h.
    @Test func weeklyUsesAverageRateAndIgnoresSamples() {
        let weekly = window(.sevenDay, 90, resetsIn: 86_400)
        let result = UsageForecast.exhaustion(window: weekly, samples: [sample(1800, 10, resetsIn: 86_400)], now: fixedNow)
        #expect(near(result, fixedNow.addingTimeInterval(16 * 3600)))
    }

    @Test func noWeeklyForecastInTheFirstSixHours() {
        let young = window(.sevenDay, 30, resetsIn: 7 * 86_400 - 3 * 3600)
        #expect(UsageForecast.exhaustion(window: young, samples: [], now: fixedNow) == nil)
    }

    @Test func noForecastAtTheLimitExpiredOrUnused() {
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 100), samples: [], now: fixedNow) == nil)
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 90, resetsIn: -1), samples: [], now: fixedNow) == nil)
        #expect(UsageForecast.exhaustion(window: window(.fiveHour, 0), samples: [], now: fixedNow) == nil)
    }
}

struct UsageHistoryTests {
    @Test func recordsFiveHourSamplesOncePerSnapshot() {
        var history = UsageHistory()
        history.record(window(.fiveHour, 10), at: fixedNow)
        history.record(window(.fiveHour, 10), at: fixedNow)
        history.record(window(.fiveHour, 12), at: fixedNow.addingTimeInterval(60))
        history.record(nil, at: fixedNow.addingTimeInterval(120))
        history.record(window(.sevenDay, 50), at: fixedNow.addingTimeInterval(180))
        #expect(history.samples.map(\.percent) == [10, 12])
    }

    @Test func dropsSamplesOlderThanAnHour() {
        var history = UsageHistory()
        history.record(window(.fiveHour, 10, resetsIn: 7200), at: fixedNow)
        history.record(window(.fiveHour, 20, resetsIn: 7200), at: fixedNow.addingTimeInterval(3601))
        #expect(history.samples.map(\.percent) == [20])
    }

    @Test func dropsSamplesFromAnotherPeriod() {
        var history = UsageHistory()
        history.record(window(.fiveHour, 90, resetsIn: 60), at: fixedNow)
        history.record(window(.fiveHour, 2, resetsIn: 5 * 3600 + 60), at: fixedNow.addingTimeInterval(120))
        #expect(history.samples.map(\.percent) == [2])
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
    }

    @Test func resetClockText() {
        #expect(LimitsText.resetClockText(fixedNow.addingTimeInterval(6 * 3600), now: fixedNow, calendar: utc) == "resets 18:00")
        #expect(LimitsText.resetClockText(fixedNow.addingTimeInterval(3 * 86_400 - 3 * 3600), now: fixedNow, calendar: utc) == "resets Thu 09:00")
    }
}
