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

    /// "runs out ~16:40" today, "runs out ~tomorrow 09:00", otherwise "runs out ~Wed 12:00".
    static func forecastText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        "runs out ~\(clockText(date, now: now, calendar: calendar))"
    }

    /// "resets 18:00" today, "resets tomorrow 09:00", otherwise "resets Thu 09:00"; shown next to a forecast.
    static func resetClockText(_ resetsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        "resets \(clockText(resetsAt, now: now, calendar: calendar))"
    }

    /// The time alone only for today: a time tomorrow, less than a day away, would read as a time that has passed.
    private static func clockText(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return formatted(date, "HH:mm", calendar: calendar)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow " + formatted(date, "HH:mm", calendar: calendar)
        }
        return formatted(date, "EEE HH:mm", calendar: calendar)
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

    static func alertTitle(_ alert: LimitsAlert, showsAccount: Bool = false) -> String {
        let suffix = showsAccount ? alertAccount(alert).map { " · \($0)" } ?? "" : ""
        switch alert {
        case let .threshold(window, threshold, _):
            return "\(window.kind.title) limit at \(threshold)%" + suffix
        case let .reset(kind, _):
            return "\(kind.title) limit reset" + suffix
        case let .sessionFinished(project, _):
            return "\(project) finished"
        case let .sessionNeedsYou(project):
            return "\(project) needs you"
        }
    }

    static func alertSubtitle(_ alert: LimitsAlert, now: Date, calendar: Calendar = .current) -> String? {
        switch alert {
        case let .threshold(window, _, _):
            let today = calendar.isDate(window.resetsAt, inSameDayAs: now)
            return "Resets \(today ? "at " : "")\(clockText(window.resetsAt, now: now, calendar: calendar))"
        case .reset:
            return nil
        case let .sessionFinished(_, worked):
            return "worked \(SessionsText.duration(from: now.addingTimeInterval(-worked), to: now))"
        case .sessionNeedsYou:
            return "permission prompt"
        }
    }

    /// The header of several alerts shown together: "2 sessions finished", "2 sessions need you", "3 alerts".
    static func batchTitle(_ alerts: [LimitsAlert]) -> String {
        let count = alerts.count
        if alerts.allSatisfy({ if case .sessionFinished = $0 { true } else { false } }) {
            return "\(count) sessions finished"
        }
        if alerts.allSatisfy({ if case .sessionNeedsYou = $0 { true } else { false } }) {
            return "\(count) sessions need you"
        }
        return "\(count) alerts"
    }

    /// One alert as a line under a batch header.
    static func batchLine(_ alert: LimitsAlert, now: Date, showsAccount: Bool = false) -> String {
        switch alert {
        case let .sessionFinished(project, worked):
            "\(project)  worked \(SessionsText.duration(from: now.addingTimeInterval(-worked), to: now))"
        case let .sessionNeedsYou(project):
            "\(project)  needs you"
        case .threshold, .reset:
            alertTitle(alert, showsAccount: showsAccount)
        }
    }

    /// The account a limit alert is about; clicking it opens the Chats window (spec §4.4).
    static func alertAccount(_ alert: LimitsAlert) -> String? {
        switch alert {
        case let .threshold(_, _, account), let .reset(_, account): account ?? ClaudeInstance.mainName
        case .sessionFinished, .sessionNeedsYou: nil
        }
    }

    /// The project a session alert is about; clicking the alert opens it.
    static func alertProject(_ alert: LimitsAlert) -> String? {
        switch alert {
        case let .sessionFinished(project, _), let .sessionNeedsYou(project): project
        case .threshold, .reset: nil
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
