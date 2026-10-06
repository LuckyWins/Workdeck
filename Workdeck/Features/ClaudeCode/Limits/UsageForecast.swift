import Foundation

/// Predicts when a window reaches 100 % at its average pace since the window started (spec §11.5).
nonisolated enum UsageForecast {
    /// Too early in a window the average pace is noise.
    static func minimumElapsed(_ kind: UsageWindowKind) -> TimeInterval {
        switch kind {
        case .fiveHour: 15 * 60
        case .sevenDay: 6 * 60 * 60
        }
    }

    /// When the window runs out at the current pace, or `nil` if it lasts until its reset or the pace is unknown.
    static func exhaustion(window: UsageWindow, now: Date) -> Date? {
        guard window.usedPercent < 100, window.resetsAt > now else { return nil }
        let start = window.resetsAt.addingTimeInterval(-window.kind.duration)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= minimumElapsed(window.kind), window.usedPercent > 0 else { return nil }
        let rate = window.usedPercent / elapsed
        let exhaustion = now.addingTimeInterval((100 - window.usedPercent) / rate)
        return exhaustion < window.resetsAt ? exhaustion : nil
    }
}
