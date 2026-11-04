import Foundation

nonisolated enum LimitsAlert: Equatable, Sendable {
    /// `account` is the block's label ("main", "personal", "codex"); `nil` means Claude's main account.
    case threshold(UsageWindow, threshold: Int, account: String? = nil, agent: AgentKind = .claudeCode)
    /// Every window of one account that reset at the same check, in `UsageWindowKind.allCases` order.
    case reset([UsageWindowKind], account: String? = nil, agent: AgentKind = .claudeCode)
    case sessionFinished(project: String, worked: TimeInterval, agent: AgentKind = .claudeCode)
    case sessionNeedsYou(project: String, agent: AgentKind = .claudeCode)
    /// A newer Workdeck was found; about the app, not an agent (in-app updates spec §2.3).
    case updateAvailable(version: String)
}

nonisolated extension LimitsAlert {
    /// The same alert, labeled with the account it is about; session alerts are unchanged.
    func forAccount(_ label: String) -> LimitsAlert {
        switch self {
        case let .threshold(window, threshold, _, agent): .threshold(window, threshold: threshold, account: label, agent: agent)
        case let .reset(kinds, _, agent): .reset(kinds, account: label, agent: agent)
        case .sessionFinished, .sessionNeedsYou, .updateAvailable: self
        }
    }

    /// The same limit alert, about another agent's limits.
    func forAgent(_ agent: AgentKind) -> LimitsAlert {
        switch self {
        case let .threshold(window, threshold, account, _): .threshold(window, threshold: threshold, account: account, agent: agent)
        case let .reset(kinds, account, _): .reset(kinds, account: account, agent: agent)
        case .sessionFinished, .sessionNeedsYou, .updateAvailable: self
        }
    }

    /// The agent an alert is about; an update alert is about the app and reports Claude Code, but nothing marks or
    /// routes it by agent (`isUpdate`).
    var agent: AgentKind {
        switch self {
        case let .threshold(_, _, _, agent), let .reset(_, _, agent), let .sessionFinished(_, _, agent), let .sessionNeedsYou(_, agent): agent
        case .updateAvailable: .claudeCode
        }
    }

    var isUpdate: Bool {
        if case .updateAvailable = self { true } else { false }
    }
}

nonisolated enum LimitsAlertPolicy {
    struct Result: Equatable, Sendable {
        var alerts: [LimitsAlert]
        var firedKeys: Set<String>
    }

    /// Keys older than this are dropped; no window period lasts longer than a week.
    static let keyRetention: TimeInterval = 8 * 24 * 60 * 60
    /// A fall of at least this many points within one period is a reset (one done on claude.ai keeps the
    /// period's end); smaller ones are rounding between sources (spec 2026-10-22 §2).
    static let inPeriodResetDrop: Double = 10

    static func evaluate(
        previous: [UsageWindow],
        current: [UsageWindow],
        thresholds: [Int],
        notifyOnReset: Bool,
        firedKeys: Set<String>,
        now: Date
    ) -> Result {
        let sortedThresholds = thresholds.sorted()
        var fired = firedKeys.filter { key in
            guard let resetsAt = resetsAt(fromKey: key) else { return false }
            return resetsAt >= now.timeIntervalSince1970 - keyRetention
        }
        var alerts: [LimitsAlert] = []

        var dropped: Set<UsageWindowKind> = []
        for window in previous {
            guard let latest = current.first(where: { $0.kind == window.kind && $0.resetsAt == window.resetsAt }),
                  latest.usedPercent <= window.usedPercent - inPeriodResetDrop
            else { continue }
            dropped.insert(window.kind)
            // Thresholds above the new value alert again when usage climbs back within this period.
            for threshold in sortedThresholds where Double(threshold) > latest.usedPercent {
                fired.remove(key(latest, threshold: threshold))
            }
        }
        // A reset Workdeck did not see (it was not running, or the snapshot was hidden) re-arms too: within a
        // period usage never sits this far below a threshold it reached.
        for window in current {
            for threshold in sortedThresholds where Double(threshold) - inPeriodResetDrop > window.usedPercent {
                fired.remove(key(window, threshold: threshold))
            }
        }

        if notifyOnReset, let first = sortedThresholds.first {
            var resetKinds: [UsageWindowKind] = []
            for window in previous where window.usedPercent >= Double(first) {
                // A window resets when its time passes, a new period arrives or it drops within its period;
                // missing data is not a reset.
                let expired = window.resetsAt <= now
                let newPeriod = current.contains { $0.kind == window.kind && $0.resetsAt != window.resetsAt }
                if expired || newPeriod || dropped.contains(window.kind) {
                    resetKinds.append(window.kind)
                }
            }
            // Windows that reset together make one alert.
            if !resetKinds.isEmpty {
                alerts.append(.reset(UsageWindowKind.allCases.filter(resetKinds.contains)))
            }
        }

        for window in current.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
            let newlyReached = sortedThresholds.filter { threshold in
                window.usedPercent >= Double(threshold) && !fired.contains(key(window, threshold: threshold))
            }
            for threshold in newlyReached {
                fired.insert(key(window, threshold: threshold))
            }
            // Jumping past both thresholds at once shows only the higher one.
            if let highest = newlyReached.last {
                alerts.append(.threshold(window, threshold: highest))
            }
        }

        return Result(alerts: alerts, firedKeys: fired)
    }

    static func key(_ window: UsageWindow, threshold: Int) -> String {
        "\(window.kind.rawValue)|\(Int(window.resetsAt.timeIntervalSince1970))|\(threshold)"
    }

    private static func resetsAt(fromKey key: String) -> TimeInterval? {
        let parts = key.split(separator: "|")
        guard parts.count == 3, let seconds = TimeInterval(parts[1]) else { return nil }
        return seconds
    }
}
