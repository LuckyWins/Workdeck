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
    /// The last prompt, which starts a turn.
    var turnStartedAt: Date?
    /// The last `Stop`; an idle status that started then means the turn finished (not an interrupt).
    var lastStopAt: Date?
    /// What compaction interrupted, restored when it ends: a manual `/compact` on an idle session stays idle.
    var statusBeforeCompact: SessionStatus?

    /// Work in progress: keeps the Mac awake when that setting is on.
    var isBusy: Bool {
        status == .working || status == .compacting || !agents.isEmpty
    }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        return URL(filePath: cwd).lastPathComponent
    }
}
