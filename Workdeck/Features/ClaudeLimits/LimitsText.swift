import Foundation

/// User-facing strings for Claude Code Limits. Pure, so they can be tested with a fixed clock and calendar.
nonisolated enum LimitsText {
    /// "resets in 1h 20m" within a day, otherwise "resets Thu 09:00".
    static func resetText(_ resetsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining < 24 * 60 * 60 else {
            return "resets \(formatted(resetsAt, "EEE HH:mm", calendar: calendar))"
        }
        let minutes = max(Int((remaining / 60).rounded(.up)), 1)
        if minutes < 60 {
            return "resets in \(minutes)m"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "resets in \(hours)h" : "resets in \(hours)h \(rest)m"
    }

    /// For a window whose reset time has passed: "reset at 14:00".
    static func expiredText(_ resetsAt: Date, calendar: Calendar = .current) -> String {
        "reset at \(formatted(resetsAt, "HH:mm", calendar: calendar))"
    }

    static func ageText(_ age: TimeInterval) -> String {
        if age < 60 {
            return "Updated just now"
        }
        if age < 60 * 60 {
            return "Updated \(Int(age / 60)) min ago"
        }
        return "Updated \(Int(age / 3600)) h ago — open Claude Code to refresh"
    }

    static func alertTitle(_ alert: LimitsAlert) -> String {
        switch alert {
        case let .threshold(window, threshold):
            "\(window.kind.title) limit at \(threshold)%"
        case let .reset(kind):
            "\(kind.title) limit reset"
        }
    }

    static func alertSubtitle(_ alert: LimitsAlert, now: Date, calendar: Calendar = .current) -> String? {
        switch alert {
        case let .threshold(window, _):
            let format = window.resetsAt.timeIntervalSince(now) < 24 * 60 * 60 ? "HH:mm" : "EEE HH:mm"
            return "Resets at \(formatted(window.resetsAt, format, calendar: calendar))"
        case .reset:
            return nil
        }
    }

    /// The popover row subtitle.
    static func rowSubtitle(
        isConnected: Bool,
        currentWindows: [UsageWindow],
        age: TimeInterval?,
        connectedAt: Date?,
        now: Date
    ) -> String {
        guard isConnected else { return "Not connected to Claude Code" }
        guard let age else {
            if let connectedAt, now.timeIntervalSince(connectedAt) > 24 * 60 * 60 {
                return "Requires a Claude Pro or Max plan"
            }
            return "Waiting for data — start a Claude Code session"
        }
        let windows = UsageWindowKind.allCases.map { kind in
            currentWindows.first { $0.kind == kind }.map(UsageFormatting.compactText) ?? "\(kind.shortLabel) —"
        }
        return (windows + ["updated \(shortAge(age))"]).joined(separator: " · ")
    }

    static func shortAge(_ age: TimeInterval) -> String {
        if age < 60 { return "just now" }
        if age < 3600 { return "\(Int(age / 60))m ago" }
        return "\(Int(age / 3600))h ago"
    }

    private static func formatted(_ date: Date, _ format: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
