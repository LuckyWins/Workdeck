import Foundation

/// Strings for the Chats window.
nonisolated enum ChatsText {
    /// "just now", "5m ago", "3h ago" (today), "yesterday", "Sep 28", "Oct 5, 2025".
    static func age(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 {
            return "just now"
        }
        if seconds < 60 * 60 {
            return "\(Int(seconds / 60))m ago"
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return "\(Int(seconds / 3600))h ago"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// "512 KB", "43 MB" (decimal units, like Finder).
    static func size(_ bytes: Int64) -> String {
        bytes < 1_000_000 ? "\(max(bytes / 1000, 1)) KB" : "\(bytes / 1_000_000) MB"
    }

    /// Where a live session runs, for the warning before continuing it elsewhere.
    static func hostName(of session: ClaudeSession) -> String {
        if session.entrypoint == "claude-vscode" {
            return "VS Code"
        }
        switch session.termProgram {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case "vscode": return "the VS Code terminal"
        case let program?: return program
        case nil: return "another window"
        }
    }
}
