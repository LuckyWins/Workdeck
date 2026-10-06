import Foundation

nonisolated enum SessionStatus: Equatable, Sendable {
    case working
    case waiting
    case idle
    case compacting
}

nonisolated struct RunningAgent: Equatable, Sendable, Identifiable {
    var id: String
    var type: String
    var description: String?
    var startedAt: Date
    /// What the agent is doing now, e.g. "Read NotchPresenter.swift".
    var action: String?
    /// The agent's latest own event; `nil` means only its start was seen.
    var lastSeenAt: Date?
}

/// A Claude Code session reconstructed from its hook events.
nonisolated struct ClaudeSession: Equatable, Sendable, Identifiable {
    var id: String
    /// The project folder: `CLAUDE_PROJECT_DIR`, or the first directory reported; not later `cd`s.
    var cwd: String?
    var status: SessionStatus
    /// When `status` last changed.
    var since: Date
    var agents: [RunningAgent] = []
    var pid: Int32?
    /// When the current `pid` was first reported; a process that started later has reused the PID.
    var pidSince: Date?
    var entrypoint: String?
    var hostBundleID: String?
    var termProgram: String?
    var lastEventAt: Date
    var hasEnded = false
    /// The agent whose permission prompt made the session wait (`nil` for the main agent).
    var waitingAgentID: String?
    /// What the main agent is doing now.
    var action: String?
    /// When the session last went from quiet to busy: the start of work that background agents may extend.
    var workStartedAt: Date?
    /// When the session last went quiet; work that resumes soon after (a background agent re-invoking
    /// the model) continues the same work.
    var quietSince: Date?
    /// The last `Stop`; an idle status that started then means the turn finished (not an interrupt).
    var lastStopAt: Date?
    /// What compaction interrupted, restored when it ends: a manual `/compact` on an idle session stays idle.
    var statusBeforeCompact: SessionStatus?

    /// Work in progress: keeps the Mac awake when that setting is on.
    var isBusy: Bool {
        status == .working || status == .compacting || !agents.isEmpty
    }

    /// An agent stopped with `TaskStop` sends no `SubagentStop`.
    var lastTaskStopAt: Date?

    /// How long after a `TaskStop` an agent may stay silent before it counts as the stopped one.
    static let taskStopGrace: TimeInterval = 30
    /// Agents silent this long are hidden whatever stopped them.
    static let silentAgentLimit: TimeInterval = 30 * 60

    /// The session without agents that were evidently stopped: silent since a `TaskStop`, or silent for
    /// half an hour. Hidden, not forgotten: an agent that is heard from again comes back.
    func withoutStoppedAgents(now: Date) -> ClaudeSession {
        var session = self
        session.agents.removeAll { agent in
            let seen = agent.lastSeenAt ?? agent.startedAt
            if now.timeIntervalSince(seen) >= Self.silentAgentLimit {
                return true
            }
            guard let stop = lastTaskStopAt else { return false }
            return seen <= stop && now.timeIntervalSince(stop) >= Self.taskStopGrace
        }
        return session
    }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        return URL(filePath: cwd).lastPathComponent
    }
}
