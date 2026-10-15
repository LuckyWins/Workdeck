import Foundation

/// Codex plan limits at one moment (Codex spec §2.1).
nonisolated struct CodexLimits: Equatable, Sendable {
    var windows: [UsageWindow]
    /// Codex's `plan_type`, e.g. "prolite".
    var plan: String?
    /// Free full resets left; only `app-server` reports them.
    var resetCredits: Int?
    var capturedAt: Date
}

/// Reads Codex limits from a session file's `token_count` lines and from `codex app-server`. Other lines are never
/// decoded: they hold prompts, answers and code.
nonisolated enum CodexRateLimits {
    static func fromSessionLine(_ line: Substring) -> CodexLimits? {
        guard line.contains("\"token_count\""),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              let time = (object["timestamp"] as? String).flatMap(date(fromISO:))
        else { return nil }
        let windows = normalized([limits["primary"], limits["secondary"]].compactMap {
            window($0, percent: "used_percent", minutes: "window_minutes", resetsAt: "resets_at")
        })
        guard !windows.isEmpty else { return nil }
        return CodexLimits(windows: windows, plan: limits["plan_type"] as? String, resetCredits: nil, capturedAt: time)
    }

    /// The newest limits in the end of a session file; the first and last lines may be cut.
    static func newest(inTail data: Data) -> CodexLimits? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            if let limits = fromSessionLine(line) {
                return limits
            }
        }
        return nil
    }

    /// The `result` of `account/rateLimits/read`.
    static func fromAppServer(_ result: [String: Any], now: Date) -> CodexLimits? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        let windows = normalized([limits["primary"], limits["secondary"]].compactMap {
            window($0, percent: "usedPercent", minutes: "windowDurationMins", resetsAt: "resetsAt")
        })
        guard !windows.isEmpty else { return nil }
        let credits = (result["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? Int
        return CodexLimits(windows: windows, plan: limits["planType"] as? String, resetCredits: credits, capturedAt: now)
    }

    /// "workdeck/0.162.1 (Mac OS …)" → "0.162.1": `app-server` answers `initialize` with the client name and its own
    /// version.
    static func version(fromUserAgent agent: String) -> String? {
        guard let slash = agent.firstIndex(of: "/") else { return nil }
        let version = agent[agent.index(after: slash)...].prefix { $0.isNumber || $0 == "." }
        return version.isEmpty ? nil : String(version)
    }

    /// 300 minutes is the 5-hour window, 10080 the weekly one; other lengths go to the nearer.
    static func kind(forMinutes minutes: Double) -> UsageWindowKind {
        abs(minutes - 300) <= abs(minutes - 10080) ? .fiveHour : .sevenDay
    }

    static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let known = ["plus": "Plus", "pro": "Pro", "prolite": "Pro Lite", "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        return known[raw.lowercased()] ?? raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private static func window(_ value: Any?, percent: String, minutes: String, resetsAt: String) -> UsageWindow? {
        guard let value = value as? [String: Any],
              let used = (value[percent] as? NSNumber)?.doubleValue,
              let length = (value[minutes] as? NSNumber)?.doubleValue,
              let resets = (value[resetsAt] as? NSNumber)?.doubleValue
        else { return nil }
        return UsageWindow(kind: kind(forMinutes: length), usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
    }

    /// One window per kind, 5-hour first.
    private static func normalized(_ windows: [UsageWindow]) -> [UsageWindow] {
        UsageWindowKind.allCases.compactMap { kind in windows.first { $0.kind == kind } }
    }

    private static func date(fromISO text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
