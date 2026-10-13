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

    private static func format(_ pattern: String, _ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
