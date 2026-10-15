import Foundation

/// How long an expanded alert or recap has left before the notch closes it (notch polish spec §3).
nonisolated struct NotchCountdown: Equatable, Sendable {
    let start: Date
    let end: Date

    init(start: Date, duration: Duration) {
        self.start = start
        let parts = duration.components
        end = start.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    /// 1 at the start, 0 at the end and after, linear between.
    func fraction(at date: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, end.timeIntervalSince(date) / total))
    }
}
