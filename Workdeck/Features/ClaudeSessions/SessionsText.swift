import Foundation

/// User-facing strings for Claude Code Sessions.
nonisolated enum SessionsText {
    static func statusText(_ status: SessionStatus) -> String {
        switch status {
        case .working: "working"
        case .waiting: "waiting for you"
        case .idle: "idle"
        }
    }

    /// "<1m", "12m", "1h 5m", "3h".
    static func duration(from start: Date, to now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(start) / 60)
        guard minutes >= 1 else { return "<1m" }
        guard minutes >= 60 else { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }

    /// The sessions part of the popover subtitle: "no sessions", "1 session", "3 sessions, 1 waiting".
    static func summary(_ state: SessionsViewState) -> String {
        guard state.totalCount > 0 else { return "no sessions" }
        let count = state.totalCount == 1 ? "1 session" : "\(state.totalCount) sessions"
        return state.waitingCount > 0 ? "\(count), \(state.waitingCount) waiting" : count
    }

    static func moreSessions(_ count: Int) -> String {
        "+\(count) more"
    }

    static func moreAgents(_ count: Int) -> String {
        count == 1 ? "+1 agent" : "+\(count) agents"
    }
}
