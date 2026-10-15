import Foundation

/// One color per project across the notch card and the Statistics window (statistics spec §3.3).
nonisolated enum RecapPalette {
    static let slots = 3

    /// The project's rank by time in the week (0, 1, 2); `nil` (gray) after the top three.
    static func slot(of project: String, in summary: WeeklyRecapSummary) -> Int? {
        guard let index = summary.projects.firstIndex(where: { $0.name == project }), index < slots else { return nil }
        return index
    }

    /// A day's projects in the week's rank order, the top project first (the bottom of a stacked bar).
    static func stack(_ day: RecapDaySplit, in summary: WeeklyRecapSummary) -> [RecapProjectTime] {
        let rank = Dictionary(uniqueKeysWithValues: summary.projects.enumerated().map { ($1.name, $0) })
        return day.projects
            .map { RecapProjectTime(name: $0.key, seconds: $0.value) }
            .sorted { (rank[$0.name] ?? .max, $0.name) < (rank[$1.name] ?? .max, $1.name) }
    }
}
