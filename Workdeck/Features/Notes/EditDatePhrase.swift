import Foundation

/// A reminder's due date written back as text when a note is edited (row menu spec §3), in a form `NoteDateParser`
/// reads as the same day and time: `Nov 12 at 16:00`, `Nov 12`, with the year when it is not this one.
nonisolated enum EditDatePhrase {
    static func phrase(for due: Date, hasTime: Bool, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: due) == calendar.component(.year, from: now)
        let day = sameYear ? "MMM d" : "MMM d, yyyy"
        formatter.dateFormat = hasTime ? "\(day) 'at' HH:mm" : day
        return formatter.string(from: due)
    }
}
