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
    var type: String
    var description: String?
    /// What the agent is doing now, shown instead of the description when known.
    var action: String?
    var startedAt: Date
    /// "Opus 5.5", or the alias ("Opus") until the transcript names the model.
    var model: String?
    var isBackground = false
    var steps = 0

    /// "Explore · Find NotchPresenter usages", or the type alone.
    var title: String {
        [type, description].compactMap { $0 }.joined(separator: " · ")
    }
}

nonisolated struct SessionRow: Equatable, Sendable, Identifiable {
    var id: String
    var projectName: String
    var status: SessionStatus
    var since: Date
    /// What the main agent is doing now.
    var action: String?
    var agents: [AgentRow]
    var hiddenAgentCount: Int
}

/// Everything the notch needs to draw the sessions part.
nonisolated struct SessionsViewState: Equatable, Sendable {
    var rows: [SessionRow] = []
    var hiddenSessionCount = 0
    var totalCount = 0
    /// Sessions that are working, compacting or waiting for you: what the compact counter shows.
    var activeCount = 0
    var waitingCount = 0
    /// Subagents running in all sessions, including ones not listed.
    var agentCount = 0
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
                action: session.action,
                agents: agents.prefix(maxAgentsPerSession).map { agent in
                    AgentRow(
                        id: agent.id,
                        type: agent.type,
                        description: agent.description,
                        action: agent.action,
                        startedAt: agent.startedAt,
                        model: (agent.modelID ?? agent.model).map(ModelName.display),
                        isBackground: agent.isBackground,
                        steps: agent.steps
                    )
                },
                hiddenAgentCount: max(0, agents.count - maxAgentsPerSession)
            )
        }
        return SessionsViewState(
            rows: Array(rows),
            hiddenSessionCount: max(0, sessions.count - maxSessions),
            totalCount: sessions.count,
            activeCount: sessions.filter { $0.status != .idle }.count,
            waitingCount: sessions.filter { $0.status == .waiting }.count,
            agentCount: sessions.reduce(0) { $0 + $1.agents.count },
            level: level(of: sessions),
            now: now
        )
    }

    private static func level(of sessions: [ClaudeSession]) -> SessionsLevel {
        if sessions.contains(where: { $0.status == .waiting }) {
            return .waiting
        }
        if sessions.contains(where: { $0.status == .working || $0.status == .compacting }) {
            return .working
        }
        return sessions.isEmpty ? .none : .idle
    }
}
