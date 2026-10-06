import Foundation

/// Parses the undocumented `GET /api/oauth/usage` response: percents 0–100 and ISO 8601 reset times.
nonisolated enum UsageAPIResponseParser {
    /// `nil` when the body is not a usage response. A response whose windows are all `null` yields
    /// a snapshot without windows, which merging treats as "no new information".
    static func snapshot(from data: Data, capturedAt: Date) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root.keys.contains("five_hour") || root.keys.contains("seven_day")
        else { return nil }
        return UsageSnapshot(
            capturedAt: capturedAt,
            fiveHour: window(.fiveHour, from: root["five_hour"]),
            sevenDay: window(.sevenDay, from: root["seven_day"])
        )
    }

    static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func window(_ kind: UsageWindowKind, from value: Any?) -> UsageWindow? {
        guard let fields = value as? [String: Any],
              let utilization = fields["utilization"] as? NSNumber,
              let resetsText = fields["resets_at"] as? String,
              let resetsAt = date(from: resetsText)
        else { return nil }
        let percent = min(max(utilization.doubleValue, 0), 100)
        return UsageWindow(kind: kind, usedPercent: percent, resetsAt: resetsAt)
    }
}
