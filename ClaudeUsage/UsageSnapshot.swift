import Foundation

nonisolated enum UsageWindowKind: String, Codable, Sendable, CaseIterable {
    case fiveHour
    case sevenDay

    /// Label used in compact text, e.g. "5h 42%".
    var shortLabel: String {
        switch self {
        case .fiveHour: "5h"
        case .sevenDay: "7d"
        }
    }

    /// Label used in expanded views and alerts.
    var title: String {
        switch self {
        case .fiveHour: "5-hour"
        case .sevenDay: "Weekly"
        }
    }
}

nonisolated struct UsageWindow: Codable, Equatable, Sendable {
    var kind: UsageWindowKind
    /// 0–100.
    var usedPercent: Double
    var resetsAt: Date
}

/// Last known Claude Code plan usage, written by `workdeck-statusline` and read by the app.
nonisolated struct UsageSnapshot: Codable, Equatable, Sendable {
    static let formatVersion = 1

    var version = UsageSnapshot.formatVersion
    var capturedAt: Date
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?

    init(capturedAt: Date, fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// Windows whose reset time has not passed yet; an expired window's usage is unknown.
    func currentWindows(at now: Date) -> [UsageWindow] {
        [fiveHour, sevenDay].compactMap { $0 }.filter { $0.resetsAt > now }
    }
}
