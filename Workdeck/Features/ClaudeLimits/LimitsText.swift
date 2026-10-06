import Foundation

/// User-facing strings for Claude Code Limits. Pure, so they can be tested with a fixed clock and calendar.
nonisolated enum LimitsText {
    /// "resets in 1h 20m" within a day, otherwise "resets Thu 09:00".
    static func resetText(_ resetsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        let short = shortResetText(resetsAt, now: now, calendar: calendar)
        return resetsAt.timeIntervalSince(now) < 24 * 60 * 60 ? "resets in \(short)" : "resets \(short)"
    }

    /// "1h 20m" within a day, otherwise "Thu 09:00".
    static func shortResetText(_ resetsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining < 24 * 60 * 60 else {
            return formatted(resetsAt, "EEE HH:mm", calendar: calendar)
        }
        let minutes = max(Int((remaining / 60).rounded(.up)), 1)
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// For a window that is not running: it begins with the next Claude Code message.
    static let notStartedText = "starts with your next message"

    /// "runs out ~16:40" within a day, otherwise "runs out ~Wed 12:00".
    static func forecastText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        "runs out ~\(clockText(date, now: now, calendar: calendar))"
    }

    /// "resets 18:00" within a day, otherwise "resets Thu 09:00"; shown next to a forecast.
    static func resetClockText(_ resetsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        "resets \(clockText(resetsAt, now: now, calendar: calendar))"
    }

    private static func clockText(_ date: Date, now: Date, calendar: Calendar) -> String {
        formatted(date, date.timeIntervalSince(now) < 24 * 60 * 60 ? "HH:mm" : "EEE HH:mm", calendar: calendar)
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
        case let .sessionFinished(project, _):
            "\(project) finished"
        case let .sessionNeedsYou(project):
            "\(project) needs you"
        }
    }

    static func alertSubtitle(_ alert: LimitsAlert, now: Date, calendar: Calendar = .current) -> String? {
        switch alert {
        case let .threshold(window, _):
            let format = window.resetsAt.timeIntervalSince(now) < 24 * 60 * 60 ? "HH:mm" : "EEE HH:mm"
            return "Resets at \(formatted(window.resetsAt, format, calendar: calendar))"
        case .reset:
            return nil
        case let .sessionFinished(_, worked):
            return "worked \(SessionsText.duration(from: now.addingTimeInterval(-worked), to: now))"
        case .sessionNeedsYou:
            return "permission prompt"
        }
    }

    /// "!" for something to act on, "✓" for good news.
    static func alertSymbol(_ alert: LimitsAlert) -> String {
        switch alert {
        case .threshold, .sessionNeedsYou: "!"
        case .reset, .sessionFinished: "✓"
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
            currentWindows.first { $0.kind == kind }.map(UsageFormatting.compactText) ?? "\(kind.shortLabel) 0%"
        }
        return (windows + ["updated \(shortAge(age))"]).joined(separator: " · ")
    }

    /// The usage API status shown in Settings; `nil` before the first attempt.
    static func pollerStatusText(_ status: UsagePollerStatus, now: Date, calendar: Calendar = .current) -> String? {
        switch status {
        case .idle:
            nil
        case let .ok(fetchedAt):
            "Last fetched \(shortAge(now.timeIntervalSince(fetchedAt)))"
        case .loginExpired:
            "Login expired — open Claude Code to refresh"
        case let .rateLimited(until):
            "Rate limited — retrying at \(formatted(until, "HH:mm", calendar: calendar))"
        case .noCredentials:
            "Claude Code login not found"
        case .keychainDenied:
            "Keychain access denied — click Refresh to try again"
        case let .failed(message):
            message
        }
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
