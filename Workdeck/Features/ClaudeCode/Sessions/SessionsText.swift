import Foundation

/// User-facing strings for Claude Code Sessions.
nonisolated enum SessionsText {
    static func statusText(_ status: SessionStatus) -> String {
        switch status {
        case .working: "working"
        case .waiting: "waiting for you"
        case .idle: "idle"
        case .compacting: "compacting"
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

    /// Tree branches for agents under their session.
    static func branch(isLast: Bool) -> String {
        isLast ? "└" : "├"
    }

    static func steps(_ count: Int) -> String {
        count == 1 ? "1 step" : "\(count) steps"
    }

    /// "+12"; `nil` for none (spec §3.3).
    static func added(_ lines: LineCounts) -> String? {
        lines.added > 0 ? "+\(lines.added)" : nil
    }

    /// "−3" with a minus sign; `nil` for none.
    static func removed(_ lines: LineCounts) -> String? {
        lines.removed > 0 ? "\u{2212}\(lines.removed)" : nil
    }

    /// "this turn · 5 files", "last turn · 1 file"; just the label when no file name was reported.
    static func turn(_ turn: TurnRow) -> String {
        let label = turn.isFinished ? "last turn" : "this turn"
        switch turn.fileCount {
        case 0: return label
        case 1: return "\(label) · 1 file"
        default: return "\(label) · \(turn.fileCount) files"
        }
    }

    static func moreSessions(_ count: Int) -> String {
        "+\(count) more"
    }

    static func moreAgents(_ count: Int) -> String {
        count == 1 ? "+1 agent" : "+\(count) agents"
    }
}
