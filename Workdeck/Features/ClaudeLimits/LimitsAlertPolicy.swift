import Foundation

nonisolated enum LimitsAlert: Equatable, Sendable {
    case threshold(UsageWindow, threshold: Int)
    case reset(UsageWindowKind)
}

/// Decides which alerts to show when new usage data arrives. Pure; the caller persists `firedKeys`.
nonisolated enum LimitsAlertPolicy {
    struct Result: Equatable, Sendable {
        var alerts: [LimitsAlert]
        var firedKeys: Set<String>
    }

    /// Keys older than this are dropped; no window period lasts longer than a week.
    static let keyRetention: TimeInterval = 8 * 24 * 60 * 60

    static func evaluate(
        previous: [UsageWindow],
        current: [UsageWindow],
        thresholds: [Int],
        notifyOnReset: Bool,
        firedKeys: Set<String>,
        now: Date
    ) -> Result {
        let sortedThresholds = thresholds.sorted()
        var fired = firedKeys.filter { key in
            guard let resetsAt = resetsAt(fromKey: key) else { return false }
            return resetsAt >= now.timeIntervalSince1970 - keyRetention
        }
        var alerts: [LimitsAlert] = []

        if notifyOnReset, let first = sortedThresholds.first {
            for window in previous where window.usedPercent >= Double(first) {
                // A window only resets when its time passes or a new period arrives; missing data is not a reset.
                let expired = window.resetsAt <= now
                let newPeriod = current.contains { $0.kind == window.kind && $0.resetsAt != window.resetsAt }
                if expired || newPeriod {
                    alerts.append(.reset(window.kind))
                }
            }
        }

        for window in current.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
            let newlyReached = sortedThresholds.filter { threshold in
                window.usedPercent >= Double(threshold) && !fired.contains(key(window, threshold: threshold))
            }
            for threshold in newlyReached {
                fired.insert(key(window, threshold: threshold))
            }
            // Jumping past both thresholds at once shows only the higher one.
            if let highest = newlyReached.last {
                alerts.append(.threshold(window, threshold: highest))
            }
        }

        return Result(alerts: alerts, firedKeys: fired)
    }

    static func key(_ window: UsageWindow, threshold: Int) -> String {
        "\(window.kind.rawValue)|\(Int(window.resetsAt.timeIntervalSince1970))|\(threshold)"
    }

    private static func resetsAt(fromKey key: String) -> TimeInterval? {
        let parts = key.split(separator: "|")
        guard parts.count == 3, let seconds = TimeInterval(parts[1]) else { return nil }
        return seconds
    }
}
