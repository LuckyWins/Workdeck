import Foundation

/// The compact notch counter's color: the most urgent session wins.
nonisolated enum SessionsLevel: Equatable, Sendable {
    case none
    case idle
    case working
    case waiting
}

nonisolated struct AgentRow: Equatable, Sendable, Identifiable {
    var id: String
    /// "Explore · Find NotchPresenter usages", or the type alone.
    var title: String
    var startedAt: Date
}

nonisolated struct SessionRow: Equatable, Sendable, Identifiable {
    var id: String
    var projectName: String
    var status: SessionStatus
    var since: Date
    var agents: [AgentRow]
    var hiddenAgentCount: Int
}

/// Everything the notch needs to draw the sessions part.
nonisolated struct SessionsViewState: Equatable, Sendable {
    var rows: [SessionRow] = []
    var hiddenSessionCount = 0
    var totalCount = 0
    var waitingCount = 0
    var level = SessionsLevel.none
    var now = Date.distantPast

    static let none = SessionsViewState()
}

nonisolated enum SessionsPresentation {
    static let maxSessions = 3
    static let maxAgentsPerSession = 2

    /// `sessions` arrive in display order from `ClaudeSessionStore`.
    static func viewState(sessions: [ClaudeSession], now: Date) -> SessionsViewState {
        let rows = sessions.prefix(maxSessions).map { session in
            let agents = session.agents.sorted { $0.startedAt < $1.startedAt }
            return SessionRow(
                id: session.id,
                projectName: session.projectName,
                status: session.status,
                since: session.since,
                agents: agents.prefix(maxAgentsPerSession).map { agent in
                    AgentRow(
                        id: agent.id,
                        title: [agent.type, agent.description].compactMap { $0 }.joined(separator: " · "),
                        startedAt: agent.startedAt
                    )
                },
                hiddenAgentCount: max(0, agents.count - maxAgentsPerSession)
            )
        }
        return SessionsViewState(
            rows: Array(rows),
            hiddenSessionCount: max(0, sessions.count - maxSessions),
            totalCount: sessions.count,
            waitingCount: sessions.filter { $0.status == .waiting }.count,
            level: level(of: sessions),
            now: now
        )
    }

    private static func level(of sessions: [ClaudeSession]) -> SessionsLevel {
        if sessions.contains(where: { $0.status == .waiting }) {
            return .waiting
        }
        if sessions.contains(where: { $0.status == .working }) {
            return .working
        }
        return sessions.isEmpty ? .none : .idle
    }
}
