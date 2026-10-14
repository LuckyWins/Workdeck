import Foundation

/// The recap card's strings (weekly recap spec §3).
nonisolated enum RecapText {
    static let title = "last week"
    static let dismiss = "Got it"

    /// "<1m", "42m", "2h 14m", "9h 03m".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        guard minutes >= 1 else { return "<1m" }
        guard minutes >= 60 else { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// "4 820" with a thin space between thousands.
    static func number(_ value: Int) -> String {
        let digits = String(abs(value))
        var groups: [String] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(String(digits[start..<end]), at: 0)
            end = start
        }
        return (value < 0 ? "-" : "") + groups.joined(separator: "\u{2009}")
    }

    /// "Oct 5–11", "Sep 28–Oct 4".
    static func weekRange(_ start: Date, calendar: Calendar) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let first = format("MMM d", start, calendar: calendar)
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        return "\(first)–\(format(sameMonth ? "d" : "MMM d", end, calendar: calendar))"
    }

    /// "Thu".
    static func dayName(_ date: Date, calendar: Calendar) -> String {
        format("EEE", date, calendar: calendar)
    }

    /// "Tue, Oct 13": the hovered day in the Statistics window's header.
    static func dayDate(_ date: Date, calendar: Calendar) -> String {
        format("EEE, MMM d", date, calendar: calendar)
    }

    /// "3 projects · 22m above the daily average"; within a minute, "about the daily average".
    static func dayDetail(projects: Int, seconds: Double, average: Double) -> String {
        let count = "\(projects) \(projects == 1 ? "project" : "projects")"
        let difference = seconds - average
        guard abs(difference) >= 60 else { return "\(count) · about the daily average" }
        return "\(count) · \(duration(abs(difference))) \(difference > 0 ? "above" : "below") the daily average"
    }

    /// "▲ 18% from the same days last week" (statistics spec §3.2); `nil` without a comparison.
    static func comparison(_ change: Double?) -> String? {
        guard let change else { return nil }
        guard abs(change) >= 0.01 else { return "about the same as the same days last week" }
        return "\(change > 0 ? "▲" : "▼") \(Int((abs(change) * 100).rounded()))% from the same days last week"
    }

    /// A chart's hour tick: "0", "15m", "1h", "1h 30m", so fractional ticks never repeat a label.
    static func axisHours(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        guard minutes > 0 else { return "0" }
        guard minutes >= 60 else { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "3h 12m a day".
    static func perDay(_ seconds: Double) -> String {
        "\(duration(seconds)) a day"
    }

    /// "1 session", "23 sessions".
    static func sessions(_ count: Int) -> String {
        "\(number(count)) \(count == 1 ? "session" : "sessions")"
    }

    /// "4 sessions · 31 files · +1 380 −290", zero parts left out (statistics spec §3.4).
    static func projectDetail(_ project: RecapProjectSummary) -> String {
        var parts: [String] = []
        if project.sessions > 0 {
            parts.append(sessions(project.sessions))
        }
        if project.files > 0 {
            parts.append("\(number(project.files)) \(project.files == 1 ? "file" : "files")")
        }
        let lines = [project.added > 0 ? "+\(number(project.added))" : nil, project.removed > 0 ? "\u{2212}\(number(project.removed))" : nil]
            .compactMap { $0 }
        if !lines.isEmpty {
            parts.append(lines.joined(separator: " "))
        }
        return parts.joined(separator: " · ")
    }

    private static func format(_ pattern: String, _ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
