import Foundation

/// Parses the undocumented `GET /api/oauth/usage` response: percents 0–100 and ISO 8601 reset times.
nonisolated enum UsageAPIResponseParser {
    /// `nil` when the body is not a usage response. A response whose windows are all `null` yields a snapshot
    /// without windows: no information about a running window, though after a switch to another account
    /// nothing of the old account's windows is kept.
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

    /// Windows reported as not started: present with `resets_at: null`, as before the first message of a
    /// period (claude limits spec §5.1). A `null` or absent window is no information and is not listed.
    static func notStartedKinds(from data: Data) -> Set<UsageWindowKind> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let keys: [(UsageWindowKind, String)] = [(.fiveHour, "five_hour"), (.sevenDay, "seven_day")]
        return Set(keys.compactMap { kind, key in
            guard let fields = root[key] as? [String: Any], fields["resets_at"] is NSNull else { return nil }
            return kind
        })
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
