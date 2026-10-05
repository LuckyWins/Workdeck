import Foundation

/// Extracts plan usage from the JSON Claude Code passes to a status line command on stdin.
/// See https://code.claude.com/docs/en/statusline (`rate_limits`).
nonisolated enum StatusLineInputParser {
    /// Returns `nil` when the input is not JSON or carries no usable `rate_limits` window.
    static func snapshot(from data: Data, capturedAt: Date) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any]
        else { return nil }
        let fiveHour = window(.fiveHour, from: limits["five_hour"])
        let sevenDay = window(.sevenDay, from: limits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return UsageSnapshot(capturedAt: capturedAt, fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func window(_ kind: UsageWindowKind, from value: Any?) -> UsageWindow? {
        guard let fields = value as? [String: Any],
              let used = fields["used_percentage"] as? NSNumber,
              let resetsAt = fields["resets_at"] as? NSNumber
        else { return nil }
        let percent = min(max(used.doubleValue, 0), 100)
        return UsageWindow(kind: kind, usedPercent: percent, resetsAt: Date(timeIntervalSince1970: resetsAt.doubleValue))
    }
}
