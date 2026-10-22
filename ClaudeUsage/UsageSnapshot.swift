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

    /// How long one period of the window lasts.
    var duration: TimeInterval {
        switch self {
        case .fiveHour: 5 * 60 * 60
        case .sevenDay: 7 * 24 * 60 * 60
        }
    }
}

nonisolated struct UsageWindow: Codable, Equatable, Sendable {
    var kind: UsageWindowKind
    /// 0–100.
    var usedPercent: Double
    var resetsAt: Date
}

/// Where a sample comes from (spec 2026-10-22 §1).
nonisolated enum UsageSource: Equatable, Sendable {
    /// The usage API: the server's current view of the login.
    case api
    /// A Claude Code session by its status line `session_id`; `nil` when the input carries none.
    case session(String?)
}

/// What one Claude Code session reported last, so its fresh samples can be told from repeats.
nonisolated struct UsageSessionMemory: Codable, Equatable, Sendable {
    /// The snapshot's account when the session was first seen; `nil` when it was unknown then.
    var account: String?
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?

    func isExpired(at now: Date) -> Bool {
        [fiveHour, sevenDay].allSatisfy { ($0?.resetsAt ?? .distantPast) <= now }
    }

    /// Fresh when one of the sample's windows is new to the session or moved. A window the session no
    /// longer reports is no change: Claude Code drops an expired window from an idle session's input.
    func isFresh(_ sample: UsageSnapshot) -> Bool {
        zip([fiveHour, sevenDay], [sample.fiveHour, sample.sevenDay]).contains { remembered, reported in
            guard let reported else { return false }
            guard let remembered else { return true }
            return reported.usedPercent != remembered.usedPercent
                || abs(reported.resetsAt.timeIntervalSince(remembered.resetsAt)) > UsageSnapshot.samePeriodTolerance
        }
    }

    mutating func remember(_ sample: UsageSnapshot) {
        fiveHour = sample.fiveHour ?? fiveHour
        sevenDay = sample.sevenDay ?? sevenDay
    }
}

/// Last known Claude Code plan usage, written by `workdeck-statusline` and the usage API poller, read by the app.
nonisolated struct UsageSnapshot: Codable, Equatable, Sendable {
    static let formatVersion = 1

    var version = UsageSnapshot.formatVersion
    var capturedAt: Date
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    /// `oauthAccount.accountUuid` of the instance the windows belong to; `nil` while not known.
    var account: String?
    /// The last report of each Claude Code session, by `session_id`.
    var sessions: [String: UsageSessionMemory]?

    init(
        capturedAt: Date,
        fiveHour: UsageWindow?,
        sevenDay: UsageWindow?,
        account: String? = nil,
        sessions: [String: UsageSessionMemory]? = nil
    ) {
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.account = account
        self.sessions = sessions
    }

    /// Windows whose reset time has not passed yet; an expired window's usage is unknown.
    func currentWindows(at now: Date) -> [UsageWindow] {
        [fiveHour, sevenDay].compactMap { $0 }.filter { $0.resetsAt > now }
    }

    /// Reset times from the status line (whole epoch seconds) and the usage API (fractional ISO 8601)
    /// differ slightly for the same period; periods themselves are hours apart.
    static let samePeriodTolerance: TimeInterval = 5 * 60

    /// How a sample's windows are applied.
    private enum Rule {
        /// The usage API: replaces in every case.
        case authoritative
        /// A status line input without a session ID: the higher percent wins within a period.
        case higher
        /// A session not seen before: it fills a missing window or a later period. Within a period it may be
        /// stale either way (lower before more usage, higher before a reset), so the existing value stays.
        case firstSeen
        /// A session whose report changed: replaces within a period, lower or higher.
        case replace
        /// A session repeating its previous report: changes nothing within a period.
        case keep
        /// A session first seen under another account: changes nothing.
        case ignored
    }

    /// Combines a new sample with the snapshot (spec 2026-10-22 §1, §3). Several Claude Code sessions and the
    /// usage API write the same file; an idle session may repeat old figures, and a reset on claude.ai lowers
    /// the percent within a period, so a sample counts by how fresh it is rather than by being higher.
    /// `account` is the instance's current account, `nil` when unknown.
    func merged(
        with incoming: UsageSnapshot,
        from source: UsageSource,
        account: String?,
        notStarted: Set<UsageWindowKind> = [],
        now: Date
    ) -> UsageSnapshot {
        let tag = account ?? self.account
        let switched = account != nil && self.account != nil && account != self.account
        var sessions = (self.sessions ?? [:]).filter { !$0.value.isExpired(at: now) }
        let rule: Rule
        switch source {
        case .api:
            rule = .authoritative
        case .session(nil):
            rule = .higher
        case let .session(id?):
            if var memory = sessions[id] {
                if let owner = memory.account, let tag, owner != tag {
                    rule = .ignored
                } else {
                    rule = memory.isFresh(incoming) ? .replace : .keep
                }
                memory.remember(incoming)
                // First seen while the account was unknown: it belongs to the first account known since.
                memory.account = memory.account ?? tag
                sessions[id] = memory
            } else {
                rule = .firstSeen
                sessions[id] = UsageSessionMemory(account: tag, fiveHour: incoming.fiveHour, sevenDay: incoming.sevenDay)
            }
        }
        if rule == .ignored || (rule == .keep && switched) {
            // No news for the current account: only the session memory changes, so a snapshot of another account
            // stays tagged with it, and hidden, until a sample that counts discards it.
            var unchanged = self
            unchanged.sessions = sessions.isEmpty ? nil : sessions
            return unchanged
        }
        var existing = self
        if switched {
            // Another account's windows; the sessions keep the account they were seen under.
            existing.fiveHour = nil
            existing.sevenDay = nil
        }
        return UsageSnapshot(
            capturedAt: incoming.capturedAt,
            fiveHour: Self.merge(existing.fiveHour, incoming.fiveHour, rule: rule, notStarted: notStarted.contains(.fiveHour), now: now),
            sevenDay: Self.merge(existing.sevenDay, incoming.sevenDay, rule: rule, notStarted: notStarted.contains(.sevenDay), now: now),
            account: tag,
            sessions: sessions.isEmpty ? nil : sessions
        )
    }

    private static func merge(_ existing: UsageWindow?, _ incoming: UsageWindow?, rule: Rule, notStarted: Bool, now: Date) -> UsageWindow? {
        let existing = existing.flatMap { $0.resetsAt > now ? $0 : nil }
        if rule == .authoritative, notStarted {
            return nil
        }
        // A window missing from the sample, or one that already ended, is no information: an idle session must not
        // erase a running one. A repeat brings none either, so it cannot restore a window the API reported as not started.
        guard let incoming, incoming.resetsAt > now, rule != .keep, rule != .ignored else { return existing }
        guard let existing else { return incoming }
        if abs(incoming.resetsAt.timeIntervalSince(existing.resetsAt)) > samePeriodTolerance {
            // Only another account's data can end later than the server's answer.
            if rule == .authoritative {
                return incoming
            }
            return incoming.resetsAt > existing.resetsAt ? incoming : existing
        }
        let percent = switch rule {
        case .higher: max(existing.usedPercent, incoming.usedPercent)
        case .firstSeen, .keep, .ignored: existing.usedPercent
        case .authoritative, .replace: incoming.usedPercent
        }
        // Keep the existing reset time so alert keys and reset detection see one stable period.
        return UsageWindow(kind: existing.kind, usedPercent: percent, resetsAt: existing.resetsAt)
    }
}
