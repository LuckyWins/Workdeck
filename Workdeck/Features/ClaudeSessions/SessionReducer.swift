import Foundation

/// Folds a session's hook events into its current state (spec §5.2).
nonisolated enum SessionReducer {
    /// Events are applied oldest first: async hooks may have written them out of order.
    static func reduce(_ events: [HookEvent]) -> ClaudeSession? {
        events
            .sorted { $0.time < $1.time }
            .reduce(nil) { session, event in apply(event, to: session) }
    }

    static func apply(_ event: HookEvent, to current: ClaudeSession?) -> ClaudeSession {
        var session = current ?? ClaudeSession(id: event.sessionID, status: .idle, since: event.time, lastEventAt: event.time)
        if event.name == .sessionStart {
            // A new process (startup or resume): drop the old state, keep what identifies the session.
            session = ClaudeSession(
                id: event.sessionID,
                cwd: session.cwd,
                status: .idle,
                since: event.time,
                pid: session.pid,
                pidSince: session.pidSince,
                entrypoint: session.entrypoint,
                hostBundleID: session.hostBundleID,
                termProgram: session.termProgram,
                lastEventAt: event.time
            )
        }
        session.cwd = event.cwd ?? session.cwd
        if let pid = event.pid, pid != session.pid {
            session.pid = pid
            session.pidSince = event.time
        }
        session.entrypoint = event.entrypoint ?? session.entrypoint
        session.hostBundleID = event.hostBundleID ?? session.hostBundleID
        session.termProgram = event.termProgram ?? session.termProgram
        session.lastEventAt = max(session.lastEventAt, event.time)

        switch event.name {
        case .sessionStart:
            break
        case .userPromptSubmit, .postToolUse:
            setStatus(.working, at: event.time, on: &session)
        case .notification:
            if event.notificationType == "permission_prompt" {
                setStatus(.waiting, at: event.time, on: &session)
            }
        case .stop:
            setStatus(.idle, at: event.time, on: &session)
        case .subagentStart:
            if let agentID = event.agentID, !session.agents.contains(where: { $0.id == agentID }) {
                session.agents.append(RunningAgent(
                    id: agentID,
                    type: event.agentType ?? "Agent",
                    description: event.agentDescription,
                    startedAt: event.time
                ))
            }
        case .subagentStop:
            session.agents.removeAll { $0.id == event.agentID }
        case .sessionEnd:
            session.hasEnded = true
        }
        return session
    }

    private static func setStatus(_ status: SessionStatus, at time: Date, on session: inout ClaudeSession) {
        guard session.status != status else { return }
        session.status = status
        session.since = time
    }
}
