import Foundation

/// Folds a session's hook events into its current state (spec §5.2).
nonisolated enum SessionReducer {
    /// How soon after the last agent stopped a re-invocation still counts as the same work.
    static let workResumeWindow: TimeInterval = 10
    /// Early counts kept for steps not seen yet; older ones belong to steps that already left the ticker.
    static let maxEarlyLines = 8

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
        // A background agent's completion re-invokes the model a moment after the session went quiet; a
        // Stop ends the work, so even a quick reply from the user starts new work.
        if wasBusy, !session.isBusy {
            session.quietSince = event.name == .subagentStop ? event.time : nil
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
        var session = current ?? ClaudeSession(id: event.sessionID, status: .idle, since: event.time, lastEventAt: event.time, turn: TurnEdits(startedAt: event.time))
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
                lastEventAt: event.time,
                isBlank: ["startup", "clear", "resume"].contains(event.source),
                turn: TurnEdits(startedAt: event.time)
            )
        } else if event.name != .sessionStart {
            session.isBlank = false
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
        session.instance = event.instance ?? session.instance
        session.lastEventAt = max(session.lastEventAt, event.time)

        switch event.name {
        case .sessionStart:
            // Compaction finished; the turn goes on (idle follows on Stop or the idle prompt).
            if event.source == "compact", session.status == .compacting {
                setStatus(session.statusBeforeCompact == .idle ? .idle : .working, at: event.time, on: &session)
            }
        case .userPromptSubmit:
            session.steps = []
            session.turn = TurnEdits(startedAt: event.time)
            session.earlyLines = []
            setStatus(.working, at: event.time, on: &session)
        case .preToolUse:
            setAction(event.action, toolUseID: event.toolUseID, for: event.agentID, at: event.time, on: &session)
            if let agentID = event.agentID, let index = session.agents.firstIndex(where: { $0.id == agentID }) {
                session.agents[index].steps += 1
            }
            if event.agentID == nil, event.action == "TaskStop" {
                session.lastTaskStopAt = event.time
            }
            if session.status != .waiting {
                setStatus(.working, at: event.time, on: &session)
            }
        case .postToolUse:
            // The finished command stays on screen until the next one starts; only mark the agent as heard from.
            markSeen(event.agentID, at: event.time, on: &session)
            if let lines = event.lineCounts {
                addEdit(lines, of: event, to: &session)
            }
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
            // Claude Code lists the background agents alive at this Stop; foreground agents have finished,
            // and a background agent missing from the list was stopped (e.g. with TaskStop).
            if let alive = event.backgroundAgentIDs {
                session.agents.removeAll { !alive.contains($0.id) }
            }
            setStatus(.idle, at: event.time, on: &session)
        case .subagentStart:
            if let agentID = event.agentID, !session.agents.contains(where: { $0.id == agentID }) {
                var agent = RunningAgent(
                    id: agentID,
                    type: event.agentType ?? "Agent",
                    description: event.agentDescription,
                    startedAt: event.time
                )
                agent.model = event.agentModel
                agent.isBackground = event.agentBackground ?? false
                agent.transcriptPath = event.agentTranscriptPath
                session.agents.append(agent)
            }
        case .subagentStop:
            session.agents.removeAll { $0.id == event.agentID }
        case .sessionEnd:
            session.hasEnded = true
        }
        return session
    }

    /// An agent's own tool call updates that agent; a call without an agent ID is the main agent's and joins the ticker.
    private static func setAction(_ action: String?, toolUseID: String?, for agentID: String?, at time: Date, on session: inout ClaudeSession) {
        guard let agentID else {
            session.action = action
            if let action {
                session.steps.append(SessionStep(toolUseID: toolUseID, action: action, lines: takeEarlyLines(toolUseID, from: &session), at: time))
                session.steps.removeFirst(max(0, session.steps.count - ClaudeSession.maxSteps))
            }
            return
        }
        // An agent that already stopped, or whose start has not been read yet, leaves the session row alone.
        if let index = session.agents.firstIndex(where: { $0.id == agentID }) {
            session.agents[index].action = action
            session.agents[index].actionToolUseID = toolUseID
            session.agents[index].actionLines = takeEarlyLines(toolUseID, from: &session)
            session.agents[index].lastSeenAt = max(session.agents[index].lastSeenAt ?? .distantPast, time)
        }
    }

    /// An applied edit joins the turn, and the step or agent action of the same tool call (spec §2.3).
    private static func addEdit(_ lines: LineCounts, of event: HookEvent, to session: inout ClaudeSession) {
        session.turn.edits += 1
        session.turn.added += lines.added
        session.turn.removed += lines.removed
        if let file = event.editedFile {
            session.turn.files.insert(file)
        }
        guard let toolUseID = event.toolUseID else { return }
        if let agentID = event.agentID, let index = session.agents.firstIndex(where: { $0.id == agentID && $0.actionToolUseID == toolUseID }) {
            session.agents[index].actionLines = lines
        } else if event.agentID == nil, let index = session.steps.firstIndex(where: { $0.toolUseID == toolUseID }) {
            session.steps[index].lines = lines
        } else {
            session.earlyLines.append(EarlyLines(toolUseID: toolUseID, lines: lines))
            session.earlyLines.removeFirst(max(0, session.earlyLines.count - maxEarlyLines))
        }
    }

    /// The counts that arrived before this tool call's step, if any.
    private static func takeEarlyLines(_ toolUseID: String?, from session: inout ClaudeSession) -> LineCounts? {
        guard let toolUseID, let index = session.earlyLines.firstIndex(where: { $0.toolUseID == toolUseID }) else { return nil }
        return session.earlyLines.remove(at: index).lines
    }

    private static func markSeen(_ agentID: String?, at time: Date, on session: inout ClaudeSession) {
        guard let agentID, let index = session.agents.firstIndex(where: { $0.id == agentID }) else { return }
        session.agents[index].lastSeenAt = max(session.agents[index].lastSeenAt ?? .distantPast, time)
    }

    private static func setStatus(_ status: SessionStatus, at time: Date, on session: inout ClaudeSession) {
        guard session.status != status else { return }
        session.status = status
        session.since = time
    }
}
