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

    /// Combines data from several Claude Code sessions sharing one account. An idle session may
    /// report fewer or older windows, so it must not erase or roll back a running window.
    func merged(with incoming: UsageSnapshot, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            capturedAt: incoming.capturedAt,
            fiveHour: Self.merge(fiveHour, incoming.fiveHour, now: now),
            sevenDay: Self.merge(sevenDay, incoming.sevenDay, now: now)
        )
    }

    /// Reset times from the status line (whole epoch seconds) and the usage API (fractional ISO 8601)
    /// differ slightly for the same period; periods themselves are hours apart.
    static let samePeriodTolerance: TimeInterval = 5 * 60

    private static func merge(_ existing: UsageWindow?, _ incoming: UsageWindow?, now: Date) -> UsageWindow? {
        let existing = existing.flatMap { $0.resetsAt > now ? $0 : nil }
        guard let incoming else { return existing }
        guard let existing else { return incoming }
        if abs(incoming.resetsAt.timeIntervalSince(existing.resetsAt)) > samePeriodTolerance {
            return incoming.resetsAt > existing.resetsAt ? incoming : existing
        }
        // Same period: usage never decreases within it, so keep the higher value. Keep the existing
        // reset time so alert keys and reset detection see one stable period.
        return UsageWindow(
            kind: existing.kind,
            usedPercent: max(existing.usedPercent, incoming.usedPercent),
            resetsAt: existing.resetsAt
        )
    }
}
