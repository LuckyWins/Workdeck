import Foundation

/// How urgent a flash is; the most urgent alert of a moment colors it (spec §2.1).
nonisolated enum NotchFlashColor: Int, Comparable, Sendable {
    case green
    case orange
    case red

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One flash of the notch; a new `id` restarts the animation even with the same colors. Limit alerts flash the
/// ring, session alerts the session dot (spec §2.1).
nonisolated struct NotchFlashEvent: Equatable, Sendable {
    var id: Int
    var ring: NotchFlashColor?
    var dot: NotchFlashColor?
    /// "Needs you" blinks the dot three times: the one alert that waits for you.
    var dotBlinks: Bool
    /// The sessions' projects whose status dots glow in the expanded notch.
    var projects: Set<String> = []
    /// The account labels ("main", "personal") whose limit blocks glow in the expanded notch.
    var accounts: Set<String> = []
    /// When the presenter published it; a view that appears later does not replay it.
    var startedAt = Date.distantPast
}

/// The flash an alert plays on the compact notch once its expanded text closes (spec `2026-10-13-notch-flash-design.md`).
nonisolated enum NotchFlash {
    static let duration: Duration = .milliseconds(1500)

    static func color(of alert: LimitsAlert, thresholds: [Int]) -> NotchFlashColor {
        switch alert {
        case .sessionFinished, .reset: .green
        case .sessionNeedsYou: .orange
        case let .threshold(_, threshold, _, _):
            thresholds.count > 1 && threshold >= (thresholds.max() ?? .max) ? .red : .orange
        }
    }

    /// The most urgent color of alerts shown together (alert badge spec §2); `nil` for none.
    static func color(of alerts: [LimitsAlert], thresholds: [Int]) -> NotchFlashColor? {
        alerts.map { color(of: $0, thresholds: thresholds) }.max()
    }

    static func event(for alerts: [LimitsAlert], thresholds: [Int], id: Int) -> NotchFlashEvent? {
        guard !alerts.isEmpty else { return nil }
        let ring = alerts.filter { !isSessionAlert($0) }.map { color(of: $0, thresholds: thresholds) }.max()
        let dot = alerts.filter(isSessionAlert).map { color(of: $0, thresholds: thresholds) }.max()
        let needsYou = alerts.contains { if case .sessionNeedsYou = $0 { true } else { false } }
        return NotchFlashEvent(
            id: id,
            ring: ring,
            dot: dot,
            dotBlinks: needsYou,
            projects: Set(alerts.compactMap(LimitsText.alertProject)),
            accounts: Set(alerts.filter { !isSessionAlert($0) }.compactMap(LimitsText.alertAccount))
        )
    }

    /// Views play a flash only when it has just started: one recreated mid-flash (the notch expanding or
    /// collapsing) stays still instead of replaying it from the start.
    static func isFresh(_ event: NotchFlashEvent, now: Date) -> Bool {
        now.timeIntervalSince(event.startedAt) < 0.25
    }

    /// A flash that arrives while another waits or plays joins it: each place keeps the more urgent color (spec §2.2).
    static func merge(_ earlier: NotchFlashEvent, _ later: NotchFlashEvent, id: Int) -> NotchFlashEvent {
        NotchFlashEvent(
            id: id,
            ring: [earlier.ring, later.ring].compactMap { $0 }.max(),
            dot: [earlier.dot, later.dot].compactMap { $0 }.max(),
            dotBlinks: earlier.dotBlinks || later.dotBlinks,
            projects: earlier.projects.union(later.projects),
            accounts: earlier.accounts.union(later.accounts)
        )
    }

    private static func isSessionAlert(_ alert: LimitsAlert) -> Bool {
        switch alert {
        case .sessionFinished, .sessionNeedsYou: true
        case .threshold, .reset: false
        }
    }
}
