import Foundation

/// The compact notch counter's color: the most urgent session wins.
nonisolated enum SessionsLevel: Equatable, Sendable {
    case none
    case idle
    case working
    case waiting
}

/// One line of the focused session's ticker (spec §3.2).
nonisolated struct StepRow: Equatable, Sendable, Identifiable {
    var id: String
    var action: String
    var lines: LineCounts?
    /// 0 for the current step, 1 for the one before, 2 for the oldest.
    var age: Int
}

/// The turn's edits, the last line of a session's block (spec §3.4).
nonisolated struct TurnRow: Equatable, Sendable {
    /// The session is idle: "last turn".
    var isFinished: Bool
    var fileCount: Int
    var lines: LineCounts
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
    var actionLines: LineCounts?

    /// "Explore · Find NotchPresenter usages", or the type alone.
    var title: String {
        [type, description].compactMap { $0 }.joined(separator: " · ")
    }

    /// The first line: what the agent works on, or its type when it has no description.
    var name: String {
        description ?? type
    }

    /// A user-defined agent type, shown next to the name; built-in types only appear in the help text.
    var customType: String? {
        guard description != nil, !SessionsPresentation.builtInAgentTypes.contains(type) else { return nil }
        return type
    }

    /// The second line: what the agent is doing now.
    var detail: String {
        action ?? "starting…"
    }
}

nonisolated struct SessionRow: Equatable, Sendable, Identifiable {
    var id: String
    var projectName: String
    /// The extra account the session runs on, shown when several instances are connected.
    var account: String?
    var status: SessionStatus
    var since: Date
    /// What the main agent is doing now.
    var action: String?
    var agents: [AgentRow]
    var hiddenAgentCount: Int
    /// Counts of the current action, once its edit is applied.
    var actionLines: LineCounts?
    /// The first working session in display order: the one that most recently started working (spec §3.2).
    var isFocused = false
    /// The focused session's last steps, oldest first; empty for other sessions.
    var steps: [StepRow] = []
    /// `nil` when the turn has no edits.
    var turn: TurnRow?
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
    /// Claude Code's own agent types say little about the task, so the description stands in for them.
    static let builtInAgentTypes: Set<String> = ["general-purpose", "Explore", "Plan"]

    /// `sessions` arrive in display order from `ClaudeSessionStore`.
    static func viewState(sessions: [ClaudeSession], now: Date, showsAccounts: Bool = false) -> SessionsViewState {
        let shown = sessions.prefix(maxSessions)
        let focusedID = shown.first { $0.status == .working || $0.status == .compacting }?.id
        let rows = shown.map { session in
            let agents = session.agents.sorted { $0.startedAt < $1.startedAt }
            return SessionRow(
                id: session.id,
                projectName: session.projectName,
                account: showsAccounts ? session.instance : nil,
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
                        steps: agent.steps,
                        actionLines: agent.actionLines
                    )
                },
                hiddenAgentCount: max(0, agents.count - maxAgentsPerSession),
                actionLines: session.action == nil ? nil : session.steps.last?.lines,
                isFocused: session.id == focusedID,
                steps: session.id == focusedID ? stepRows(session.steps) : [],
                turn: turnRow(session)
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

    /// The ticker without agent launches, which the agent cards show. While the latest step launched an agent, no step
    /// is current: the agent is what runs now.
    static func stepRows(_ steps: [SessionStep]) -> [StepRow] {
        let recent = Array(steps.suffix(ClaudeSession.maxSteps))
        let shown = recent.filter { !launchesAgent($0.action) }
        let waitsForAgent = recent.last.map { launchesAgent($0.action) } ?? false
        return shown.enumerated().map { index, step in
            let age = shown.count - 1 - index + (waitsForAgent ? 1 : 0)
            return StepRow(
                id: step.toolUseID ?? "\(step.at.timeIntervalSince1970) \(step.action)",
                action: step.action,
                lines: step.lines,
                age: age
            )
        }
    }

    /// "Agent Explore", "Task": the actions `HookPayloadFilter` gives the Agent and Task tools.
    static func launchesAgent(_ action: String) -> Bool {
        ["Agent", "Task"].contains { action == $0 || action.hasPrefix($0 + " ") }
    }

    static func turnRow(_ session: ClaudeSession) -> TurnRow? {
        guard session.turn.edits > 0 else { return nil }
        return TurnRow(
            isFinished: session.status == .idle,
            fileCount: session.turn.files.count,
            lines: LineCounts(added: session.turn.added, removed: session.turn.removed)
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
