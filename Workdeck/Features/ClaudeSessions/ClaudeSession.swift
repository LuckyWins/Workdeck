import Foundation

nonisolated enum SessionStatus: Equatable, Sendable {
    case working
    case waiting
    case idle
}

nonisolated struct RunningAgent: Equatable, Sendable, Identifiable {
    var id: String
    var type: String
    var description: String?
    var startedAt: Date
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

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        return URL(filePath: cwd).lastPathComponent
    }
}
