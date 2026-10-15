import Foundation

/// `recap.json`: the daily totals of the last twelve weeks (weekly recap spec §4).
nonisolated struct RecapStore: Sendable {
    static let keptWeeks = 12

    let url: URL

    static func standard() -> RecapStore {
        RecapStore(url: WorkdeckPaths.standard().supportDirectory.appending(path: "recap.json"))
    }

    private struct File: Codable {
        var schemaVersion = 2
        var days: [RecapDay]
    }

    /// The kept days; empty without a file. A file that cannot be read is set aside, so counting starts over.
    func load(now: Date, calendar: Calendar) -> [RecapDay] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            let aside = url.deletingLastPathComponent().appending(path: "recap.corrupt-\(Int(now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return []
        }
        return Self.pruned(file.days, now: now, calendar: calendar)
    }

    func save(_ days: [RecapDay], now: Date, calendar: Calendar) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(File(days: Self.pruned(days, now: now, calendar: calendar))).write(to: url, options: .atomic)
    }

    /// This week and the twelve full weeks before it.
    static func pruned(_ days: [RecapDay], now: Date, calendar: Calendar) -> [RecapDay] {
        let thisWeek = RecapCalendar.weekStart(of: now, calendar: calendar)
        guard let first = calendar.date(byAdding: .weekOfYear, value: -keptWeeks, to: thisWeek) else { return days }
        let firstKey = RecapCalendar.dayKey(first, calendar: calendar)
        return days.filter { $0.date >= firstKey }
    }
}
