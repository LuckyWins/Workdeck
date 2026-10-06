import Foundation

/// One observation of the 5-hour window, used for its recent rate.
nonisolated struct UsageSample: Equatable, Sendable {
    var date: Date
    var percent: Double
    var resetsAt: Date
}

/// Predicts when a window reaches 100 % (spec §11.5).
nonisolated enum UsageForecast {
    static let recentSpan: TimeInterval = 60 * 60
    static let minimumRecentSpan: TimeInterval = 10 * 60

    static func minimumElapsed(_ kind: UsageWindowKind) -> TimeInterval {
        switch kind {
        case .fiveHour: 15 * 60
        case .sevenDay: 6 * 60 * 60
        }
    }

    /// When the window runs out at the current pace, or `nil` if it lasts until its reset or the pace is unknown.
    static func exhaustion(window: UsageWindow, samples: [UsageSample], now: Date) -> Date? {
        guard window.usedPercent < 100, window.resetsAt > now else { return nil }
        guard let rate = recentRate(window: window, samples: samples, now: now) ?? averageRate(window: window, now: now),
              rate > 0
        else { return nil }
        let exhaustion = now.addingTimeInterval((100 - window.usedPercent) / rate)
        return exhaustion < window.resetsAt ? exhaustion : nil
    }

    /// Percent per second since the oldest sample of the last hour; `nil` without enough history.
    private static func recentRate(window: UsageWindow, samples: [UsageSample], now: Date) -> Double? {
        guard window.kind == .fiveHour else { return nil }
        let oldest = samples
            .filter { sample in
                abs(sample.resetsAt.timeIntervalSince(window.resetsAt)) <= UsageSnapshot.samePeriodTolerance
                    && sample.date <= now
                    && now.timeIntervalSince(sample.date) <= recentSpan
            }
            .min { $0.date < $1.date }
        guard let oldest else { return nil }
        let span = now.timeIntervalSince(oldest.date)
        guard span >= minimumRecentSpan else { return nil }
        return (window.usedPercent - oldest.percent) / span
    }

    /// Percent per second since the window started.
    private static func averageRate(window: UsageWindow, now: Date) -> Double? {
        let start = window.resetsAt.addingTimeInterval(-window.kind.duration)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= minimumElapsed(window.kind) else { return nil }
        return window.usedPercent / elapsed
    }
}

/// Recent 5-hour samples, kept in memory only; empty after a relaunch.
nonisolated struct UsageHistory: Equatable, Sendable {
    private(set) var samples: [UsageSample] = []

    /// Adds the snapshot's 5-hour window once per snapshot time and drops stale or other-period samples.
    mutating func record(_ window: UsageWindow?, at date: Date) {
        guard let window, window.kind == .fiveHour else { return }
        samples.removeAll { sample in
            abs(sample.resetsAt.timeIntervalSince(window.resetsAt)) > UsageSnapshot.samePeriodTolerance
                || date.timeIntervalSince(sample.date) > UsageForecast.recentSpan
        }
        guard !samples.contains(where: { $0.date == date }) else { return }
        samples.append(UsageSample(date: date, percent: window.usedPercent, resetsAt: window.resetsAt))
    }
}
