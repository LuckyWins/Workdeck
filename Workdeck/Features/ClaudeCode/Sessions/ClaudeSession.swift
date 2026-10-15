import Foundation

nonisolated enum SessionStatus: Equatable, Sendable {
    case working
    case waiting
    case idle
    case compacting
}

/// One of the main agent's recent tool calls (spec §2.3).
nonisolated struct SessionStep: Equatable, Sendable {
    var toolUseID: String?
    var action: String
    /// Set when the call's edit is applied.
    var lines: LineCounts?
    var at: Date
}

/// Edits since the last prompt, by the main agent and every agent (spec §2.3). Files are told apart by name.
nonisolated struct TurnEdits: Equatable, Sendable {
    var startedAt: Date
    /// Applied edits with counts.
    var edits = 0
    var added = 0
    var removed = 0
    var files: Set<String> = []
}

/// An applied edit's counts waiting for its tool call's step.
nonisolated struct EarlyLines: Equatable, Sendable {
    var toolUseID: String
    var lines: LineCounts
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
    /// A model alias from `meta.json` ("opus"); `modelID` is the full ID once read from the transcript.
    var model: String?
    var modelID: String?
    var isBackground = false
    /// Tool calls the agent made.
    var steps = 0
    var transcriptPath: String?
    /// The tool call of `action`, and its counts once its edit is applied.
    var actionToolUseID: String?
    var actionLines: LineCounts?
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
    /// The extra instance the session runs in; `nil` for the main one.
    var instance: String?
    var lastEventAt: Date
    var hasEnded = false
    /// A conversation with nothing new in it yet, not listed: a new one (startup or `/clear`), e.g. an empty VS Code tab, or
    /// a resumed one, e.g. a chat tab VS Code revived when its window opened.
    var isBlank = false
    /// The agent whose permission prompt made the session wait (`nil` for the main agent).
    var waitingAgentID: String?
    /// The wait came from Codex's `PermissionRequest`: the asking agent calls its next tool only once it is answered.
    var waitEndsOnNextCall = false
    /// What the main agent is doing now.
    var action: String?
    /// When the session last went from quiet to busy: the start of work that background agents may extend.
    var workStartedAt: Date?
    /// When the session last went quiet because its last agent stopped; the model re-invoked right after
    /// (a background agent's result) continues the same work. A Stop closes the work instead.
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
    /// The main agent's last tool calls, oldest first, at most `maxSteps`; a prompt clears them.
    var steps: [SessionStep] = []
    var turn = TurnEdits(startedAt: .distantPast)
    /// Bash tool calls of the session and its agents (weekly recap spec §2).
    var commands = 0
    /// Counts whose step was not seen yet: each hook stamps its own time, so a fast edit's PostToolUse can come first.
    var earlyLines: [EarlyLines] = []
    /// Codex only: the session file the app counts patch lines in (Codex spec §3.3).
    var transcriptPath: String?
    /// The agent the session belongs to (Codex spec §3.3).
    var agent: AgentKind = .claudeCode

    static let maxSteps = 3

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
