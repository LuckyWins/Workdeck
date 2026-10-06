import Foundation

/// Folds a session's hook events into its current state (spec §5.2).
nonisolated enum SessionReducer {
    /// How soon after going quiet new activity still counts as the same work.
    static let workResumeWindow: TimeInterval = 60

    /// Events are applied oldest first: async hooks may have written them out of order.
    static func reduce(_ events: [HookEvent]) -> ClaudeSession? {
        events
            .sorted { $0.time < $1.time }
            .reduce(nil) { session, event in apply(event, to: session) }
    }

    static func apply(_ event: HookEvent, to current: ClaudeSession?) -> ClaudeSession {
        let wasBusy = current?.isBusy ?? false
        var session = applyEvent(event, to: current)
        // Work starts when a quiet session gets busy and lasts until it is quiet again, agents included.
        // A background agent's completion re-invokes the model a moment after the session went quiet.
        if wasBusy, !session.isBusy {
            session.quietSince = event.time
        } else if !wasBusy, session.isBusy {
            let resumesWork = session.quietSince.map { event.time.timeIntervalSince($0) <= workResumeWindow } ?? false
            if !resumesWork || session.workStartedAt == nil {
                session.workStartedAt = event.time
            }
            session.quietSince = nil
        }
        return session
    }

    private static func applyEvent(_ event: HookEvent, to current: ClaudeSession?) -> ClaudeSession {
        var session = current ?? ClaudeSession(id: event.sessionID, status: .idle, since: event.time, lastEventAt: event.time)
        // Compaction keeps the session running; startup, resume and clear begin afresh.
        if event.name == .sessionStart, event.source != "compact" {
            session = ClaudeSession(
                id: event.sessionID,
                cwd: event.projectDir ?? event.cwd ?? session.cwd,
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
        // The Bash tool keeps `cd` between commands, so a later `cwd` is not the project.
        if let projectDir = event.projectDir {
            session.cwd = projectDir
        } else if session.cwd == nil {
            session.cwd = event.cwd
        }
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
            // Compaction finished; the turn goes on (idle follows on Stop or the idle prompt).
            if event.source == "compact", session.status == .compacting {
                setStatus(session.statusBeforeCompact == .idle ? .idle : .working, at: event.time, on: &session)
            }
        case .userPromptSubmit:
            setStatus(.working, at: event.time, on: &session)
        case .preToolUse:
            setAction(event.action, for: event.agentID, on: &session)
            if session.status != .waiting {
                setStatus(.working, at: event.time, on: &session)
            }
        case .postToolUse:
            setAction(nil, for: event.agentID, on: &session)
            // Agents run in parallel: only the agent that asked for permission ends the wait.
            if session.status != .waiting || event.agentID == session.waitingAgentID {
                setStatus(.working, at: event.time, on: &session)
            }
        case .preCompact:
            if session.status != .compacting {
                session.statusBeforeCompact = session.status
            }
            setStatus(.compacting, at: event.time, on: &session)
        case .notification:
            switch event.notificationType {
            case "permission_prompt":
                setStatus(.waiting, at: event.time, on: &session)
                session.waitingAgentID = event.agentID
            case "idle_prompt":
                // An interrupt (Esc) or a denied permission sends no Stop; this arrives about a minute later.
                setStatus(.idle, at: event.time, on: &session)
            default:
                break
            }
        case .stop:
            session.action = nil
            session.lastStopAt = event.time
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

    /// An agent's own tool call updates that agent; a call without an agent ID is the main agent's.
    private static func setAction(_ action: String?, for agentID: String?, on session: inout ClaudeSession) {
        guard let agentID else {
            session.action = action
            return
        }
        // An agent that already stopped, or whose start has not been read yet, leaves the session row alone.
        if let index = session.agents.firstIndex(where: { $0.id == agentID }) {
            session.agents[index].action = action
        }
    }

    private static func setStatus(_ status: SessionStatus, at time: Date, on session: inout ClaudeSession) {
        guard session.status != status else { return }
        session.status = status
        session.since = time
    }
}
