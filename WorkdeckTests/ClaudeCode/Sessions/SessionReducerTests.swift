import Foundation
import Testing
@testable import Workdeck

func hookEvent(_ name: HookEventName, at seconds: TimeInterval, session: String = "s1", configure: (inout HookEvent) -> Void = { _ in }) -> HookEvent {
    var event = HookEvent(time: fixedNow.addingTimeInterval(seconds), name: name, sessionID: session)
    configure(&event)
    return event
}

struct SessionReducerTests {
    private let start = hookEvent(.sessionStart, at: 0) {
        $0.cwd = "/p/Workdeck"
        $0.pid = 42
        $0.entrypoint = "claude-vscode"
        $0.hostBundleID = "com.microsoft.VSCode"
    }

    @Test func noEventsNoSession() {
        #expect(SessionReducer.reduce([]) == nil)
    }

    @Test func sessionStartIsIdleWithProcessAndHost() throws {
        let session = try #require(SessionReducer.reduce([start]))
        #expect(session.status == .idle)
        #expect(session.since == fixedNow)
        #expect(session.pid == 42)
        #expect(session.pidSince == fixedNow)
        #expect(session.entrypoint == "claude-vscode")
        #expect(session.hostBundleID == "com.microsoft.VSCode")
        #expect(session.projectName == "Workdeck")
        #expect(!session.hasEnded)
    }

    @Test func promptAndToolUseMeanWorking() throws {
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), hookEvent(.postToolUse, at: 20)]))
        #expect(session.status == .working)
        #expect(session.since == fixedNow.addingTimeInterval(10))
        #expect(session.lastEventAt == fixedNow.addingTimeInterval(20))
    }

    @Test func permissionPromptMeansWaitingUntilTheToolRuns() throws {
        let prompt = hookEvent(.notification, at: 20) { $0.notificationType = "permission_prompt" }
        let waiting = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), prompt]))
        #expect(waiting.status == .waiting)
        #expect(waiting.since == fixedNow.addingTimeInterval(20))
        let resumed = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), prompt, hookEvent(.postToolUse, at: 30)]))
        #expect(resumed.status == .working)
        #expect(resumed.since == fixedNow.addingTimeInterval(30))
    }

    @Test func otherNotificationsChangeNothing() throws {
        let other = hookEvent(.notification, at: 20) { $0.notificationType = "auth_success" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), other]))
        #expect(session.status == .working)
        #expect(session.since == fixedNow.addingTimeInterval(10))
    }

    @Test func agentsStartAndStop() throws {
        let explore = hookEvent(.subagentStart, at: 5) {
            $0.agentID = "a1"
            $0.agentType = "Explore"
            $0.agentDescription = "Find NotchPresenter usages"
        }
        let general = hookEvent(.subagentStart, at: 6) { $0.agentID = "a2"; $0.agentType = "general-purpose" }
        let duplicate = hookEvent(.subagentStart, at: 7) { $0.agentID = "a2"; $0.agentType = "general-purpose" }
        let stop = hookEvent(.subagentStop, at: 8) { $0.agentID = "a1" }
        let session = try #require(SessionReducer.reduce([start, explore, general, duplicate, stop]))
        #expect(session.agents == [RunningAgent(id: "a2", type: "general-purpose", description: nil, startedAt: fixedNow.addingTimeInterval(6))])
        let running = try #require(SessionReducer.reduce([start, explore]))
        #expect(running.agents == [RunningAgent(id: "a1", type: "Explore", description: "Find NotchPresenter usages", startedAt: fixedNow.addingTimeInterval(5))])
    }

    @Test func stopMeansIdleAndKeepsBackgroundAgents() throws {
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 1), agent, hookEvent(.stop, at: 9)]))
        #expect(session.status == .idle)
        #expect(session.agents.map(\.id) == ["a1"])
    }

    @Test func ordersEventsByTime() throws {
        // Async hooks can finish out of order: a late PostToolUse may be written after Stop.
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), hookEvent(.stop, at: 30), hookEvent(.postToolUse, at: 20)]))
        #expect(session.status == .idle)
        #expect(session.since == fixedNow.addingTimeInterval(30))
    }

    @Test func newConversationIsBlankUntilSomethingHappens() throws {
        for source in ["startup", "clear"] {
            let fresh = hookEvent(.sessionStart, at: 0) { $0.source = source }
            #expect(try #require(SessionReducer.reduce([fresh])).isBlank)
            #expect(try #require(SessionReducer.reduce([fresh, hookEvent(.userPromptSubmit, at: 5)])).isBlank == false)
        }
    }

    @Test func resumedOrUnknownStartIsNotBlank() throws {
        let resume = hookEvent(.sessionStart, at: 0) { $0.source = "resume" }
        #expect(try #require(SessionReducer.reduce([resume])).isBlank == false)
        #expect(try #require(SessionReducer.reduce([start])).isBlank == false)
        // Hooks connected mid-session: the first event seen is not a start.
        #expect(try #require(SessionReducer.reduce([hookEvent(.postToolUse, at: 0)])).isBlank == false)
    }

    @Test func sessionEndMarksTheSessionEnded() throws {
        let session = try #require(SessionReducer.reduce([start, hookEvent(.sessionEnd, at: 5)]))
        #expect(session.hasEnded)
    }

    @Test func resumeInANewProcessResets() throws {
        let agent = hookEvent(.subagentStart, at: 12) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let resume = hookEvent(.sessionStart, at: 30) { $0.pid = 77; $0.source = "resume" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), agent, hookEvent(.sessionEnd, at: 20), resume]))
        #expect(session.status == .idle)
        #expect(session.agents.isEmpty)
        #expect(!session.hasEnded)
        #expect(session.pid == 77)
        #expect(session.pidSince == fixedNow.addingTimeInterval(30))
        #expect(session.cwd == "/p/Workdeck")
        #expect(session.hostBundleID == "com.microsoft.VSCode")
    }

    @Test func missingFieldsKeepPreviousValues() throws {
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10) { $0.pid = 42 }]))
        #expect(session.cwd == "/p/Workdeck")
        #expect(session.pid == 42)
        #expect(session.pidSince == fixedNow)
    }

    @Test func eventsWithoutSessionStartStillMakeASession() throws {
        let session = try #require(SessionReducer.reduce([hookEvent(.userPromptSubmit, at: 5) { $0.cwd = "/p/pokemon" }]))
        #expect(session.status == .working)
        #expect(session.projectName == "pokemon")
    }

    @Test func projectNameFallsBackWithoutAFolder() throws {
        let session = try #require(SessionReducer.reduce([hookEvent(.stop, at: 0)]))
        #expect(session.projectName == "Claude Code")
    }

    @Test func idlePromptMeansIdleAfterAnInterrupt() throws {
        // Esc or a denied permission sends no Stop; Claude Code reports the idle prompt about a minute later.
        let prompt = hookEvent(.notification, at: 20) { $0.notificationType = "permission_prompt" }
        let idle = hookEvent(.notification, at: 80) { $0.notificationType = "idle_prompt" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), prompt, idle]))
        #expect(session.status == .idle)
        #expect(session.since == fixedNow.addingTimeInterval(80))
    }

    @Test func waitingIgnoresOtherAgentsToolCalls() throws {
        let prompt = hookEvent(.notification, at: 20) { $0.notificationType = "permission_prompt" }
        let otherAgent = hookEvent(.postToolUse, at: 21) { $0.agentID = "a1" }
        let waiting = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), prompt, otherAgent]))
        #expect(waiting.status == .waiting)
        let resumed = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), prompt, otherAgent, hookEvent(.postToolUse, at: 22)]))
        #expect(resumed.status == .working)
    }

    @Test func agentWaitingClearsOnItsOwnToolCall() throws {
        let prompt = hookEvent(.notification, at: 20) { $0.notificationType = "permission_prompt"; $0.agentID = "a1" }
        let main = hookEvent(.postToolUse, at: 21)
        let own = hookEvent(.postToolUse, at: 22) { $0.agentID = "a1" }
        #expect(SessionReducer.reduce([start, prompt, main])?.status == .waiting)
        #expect(SessionReducer.reduce([start, prompt, main, own])?.status == .working)
    }

    @Test func compactionKeepsStatusAndAgents() throws {
        let agent = hookEvent(.subagentStart, at: 12) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let compact = hookEvent(.sessionStart, at: 30) { $0.source = "compact"; $0.pid = 42 }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), agent, compact]))
        #expect(session.status == .working)
        #expect(session.since == fixedNow.addingTimeInterval(10))
        #expect(session.agents.map(\.id) == ["a1"])
    }

    @Test func projectFolderSurvivesChangingDirectory() throws {
        let cd = hookEvent(.postToolUse, at: 10) { $0.cwd = "/p/Workdeck/packages/foo" }
        let session = try #require(SessionReducer.reduce([start, cd]))
        #expect(session.cwd == "/p/Workdeck")
        #expect(session.projectName == "Workdeck")
    }

    @Test func projectDirectoryFromClaudeCodeWins() throws {
        let event = hookEvent(.userPromptSubmit, at: 10) { $0.cwd = "/p/Workdeck/sub"; $0.projectDir = "/p/Root" }
        #expect(SessionReducer.reduce([start, event])?.projectName == "Root")
    }

    @Test func promptStartsWork() throws {
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10)]))
        #expect(session.workStartedAt == fixedNow.addingTimeInterval(10))
    }

    @Test func preToolUseSetsTheSessionAction() throws {
        let tool = hookEvent(.preToolUse, at: 11) { $0.action = "Bash ls" }
        let running = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), tool]))
        #expect(running.action == "Bash ls")
        #expect(running.status == .working)
        // The last command stays until the next one starts, so nothing flickers between commands.
        let done = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), tool, hookEvent(.postToolUse, at: 12)]))
        #expect(done.action == "Bash ls")
    }

    @Test func preToolUseOfAnAgentSetsItsAction() throws {
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let tool = hookEvent(.preToolUse, at: 6) { $0.agentID = "a1"; $0.action = "Read x.swift" }
        let running = try #require(SessionReducer.reduce([start, agent, tool]))
        #expect(running.agents.first?.action == "Read x.swift")
        #expect(running.action == nil)
        let done = try #require(SessionReducer.reduce([start, agent, tool, hookEvent(.postToolUse, at: 7) { $0.agentID = "a1" }]))
        #expect(done.agents.first?.action == "Read x.swift")
        #expect(done.agents.first?.lastSeenAt == fixedNow.addingTimeInterval(7))
    }

    @Test func preToolUseDoesNotEndAWait() throws {
        let prompt = hookEvent(.notification, at: 20) { $0.notificationType = "permission_prompt" }
        let tool = hookEvent(.preToolUse, at: 21) { $0.action = "Bash ls" }
        #expect(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), prompt, tool])?.status == .waiting)
    }

    @Test func stopClearsTheActionAndRecordsWhen() throws {
        let tool = hookEvent(.preToolUse, at: 11) { $0.action = "Bash ls" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), tool, hookEvent(.stop, at: 30)]))
        #expect(session.action == nil)
        #expect(session.lastStopAt == fixedNow.addingTimeInterval(30))
        #expect(session.status == .idle)
    }

    @Test func compactionReturnsToWorking() throws {
        let compacting = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), hookEvent(.preCompact, at: 20)]))
        #expect(compacting.status == .compacting)
        #expect(compacting.since == fixedNow.addingTimeInterval(20))
        let resumed = try #require(SessionReducer.reduce([
            start, hookEvent(.userPromptSubmit, at: 10), hookEvent(.preCompact, at: 20),
            hookEvent(.sessionStart, at: 25) { $0.source = "compact" },
        ]))
        #expect(resumed.status == .working)
        #expect(resumed.since == fixedNow.addingTimeInterval(25))
        #expect(resumed.lastStopAt == nil)
    }

    @Test func busyMeansWorkingCompactingOrRunningAgents() throws {
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        #expect(SessionReducer.reduce([start])?.isBusy == false)
        #expect(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 1)])?.isBusy == true)
        #expect(SessionReducer.reduce([start, hookEvent(.preCompact, at: 1)])?.isBusy == true)
        #expect(SessionReducer.reduce([start, agent, hookEvent(.stop, at: 9)])?.isBusy == true)
    }

    @Test func aTurnWithoutAPromptStartsWhenWorkResumes() throws {
        // A background task or wake-up re-invokes the model without UserPromptSubmit.
        let session = try #require(SessionReducer.reduce([
            start, hookEvent(.userPromptSubmit, at: 1), hookEvent(.stop, at: 60),
            hookEvent(.preToolUse, at: 7200) { $0.action = "Bash ls" }, hookEvent(.stop, at: 7230),
        ]))
        #expect(session.workStartedAt == fixedNow.addingTimeInterval(7200))
    }

    @Test func manualCompactOnAnIdleSessionReturnsToIdle() throws {
        let session = try #require(SessionReducer.reduce([
            start, hookEvent(.preCompact, at: 5), hookEvent(.sessionStart, at: 6) { $0.source = "compact" },
        ]))
        #expect(session.status == .idle)
        #expect(!session.isBusy)
    }

    @Test func stepsOfUnknownAgentsLeaveTheSessionRowAlone() throws {
        let main = hookEvent(.preToolUse, at: 10) { $0.action = "Agent Explore" }
        let agentStart = hookEvent(.subagentStart, at: 11) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let agentStop = hookEvent(.subagentStop, at: 20) { $0.agentID = "a1" }
        // The stopped agent's late PostToolUse, and a step from an agent not seen yet.
        let lateAgentTool = hookEvent(.postToolUse, at: 21) { $0.agentID = "a1" }
        let unknownAgentTool = hookEvent(.preToolUse, at: 22) { $0.agentID = "a9"; $0.action = "Read z.swift" }
        let session = try #require(SessionReducer.reduce([start, main, agentStart, agentStop, lateAgentTool, unknownAgentTool]))
        #expect(session.action == "Agent Explore")
    }

    @Test func workSpansBackgroundAgentsUntilTheSessionIsQuiet() throws {
        // A background agent keeps the work going after Stop; its completion re-invokes the model.
        let agentStart = hookEvent(.subagentStart, at: 20) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let agentStop = hookEvent(.subagentStop, at: 600) { $0.agentID = "a1" }
        let events = [
            start, hookEvent(.userPromptSubmit, at: 10), agentStart, hookEvent(.stop, at: 30),
            agentStop, hookEvent(.userPromptSubmit, at: 601), hookEvent(.stop, at: 620),
        ]
        let session = try #require(SessionReducer.reduce(events))
        #expect(session.workStartedAt == fixedNow.addingTimeInterval(10))
        let next = try #require(SessionReducer.reduce(events + [hookEvent(.userPromptSubmit, at: 900)]))
        #expect(next.workStartedAt == fixedNow.addingTimeInterval(900))
    }

    private var twoAgentsAndATaskStop: [HookEvent] {
        [
            start,
            hookEvent(.subagentStart, at: 0) { $0.agentID = "a1"; $0.agentType = "general-purpose" },
            hookEvent(.subagentStart, at: 0) { $0.agentID = "a2"; $0.agentType = "general-purpose" },
            hookEvent(.preToolUse, at: 10) { $0.agentID = "a1"; $0.action = "WebFetch x.com" },
            hookEvent(.preToolUse, at: 10) { $0.agentID = "a2"; $0.action = "Bash ls" },
            // The main agent stops a1 with TaskStop; no SubagentStop arrives for it.
            hookEvent(.preToolUse, at: 20) { $0.action = "TaskStop" },
            hookEvent(.postToolUse, at: 25) { $0.agentID = "a2" },
        ]
    }

    @Test func agentsSilentSinceATaskStopAreHidden() throws {
        let session = try #require(SessionReducer.reduce(twoAgentsAndATaskStop))
        #expect(session.withoutStoppedAgents(now: fixedNow.addingTimeInterval(60)).agents.map(\.id) == ["a2"])
        #expect(session.withoutStoppedAgents(now: fixedNow.addingTimeInterval(40)).agents.map(\.id) == ["a1", "a2"])
    }

    @Test func aHiddenAgentReturnsWhenItIsHeardFrom() throws {
        let events = twoAgentsAndATaskStop + [hookEvent(.preToolUse, at: 90) { $0.agentID = "a1"; $0.action = "Read y.swift" }]
        let session = try #require(SessionReducer.reduce(events))
        #expect(session.withoutStoppedAgents(now: fixedNow.addingTimeInterval(120)).agents.map(\.id) == ["a1", "a2"])
    }

    @Test func agentsSilentForHalfAnHourAreHidden() throws {
        let session = try #require(SessionReducer.reduce([
            start, hookEvent(.subagentStart, at: 0) { $0.agentID = "a1"; $0.agentType = "Explore" },
        ]))
        #expect(session.withoutStoppedAgents(now: fixedNow.addingTimeInterval(1700)).agents.count == 1)
        #expect(session.withoutStoppedAgents(now: fixedNow.addingTimeInterval(1801)).agents.isEmpty)
    }

    @Test func agentsCarryTheirMetaAndCountSteps() throws {
        let agentStart = hookEvent(.subagentStart, at: 1) {
            $0.agentID = "a1"
            $0.agentType = "general-purpose"
            $0.agentModel = "opus"
            $0.agentBackground = true
            $0.agentTranscriptPath = "/t/agent-a1.jsonl"
        }
        let steps = (2...4).map { second in hookEvent(.preToolUse, at: TimeInterval(second)) { $0.agentID = "a1"; $0.action = "Bash ls" } }
        let main = hookEvent(.preToolUse, at: 5) { $0.action = "Read x.swift" }
        let agent = try #require(SessionReducer.reduce([start, agentStart] + steps + [main])?.agents.first)
        #expect(agent.model == "opus")
        #expect(agent.isBackground)
        #expect(agent.transcriptPath == "/t/agent-a1.jsonl")
        #expect(agent.steps == 3)
    }

    @Test func stopKeepsListedBackgroundAgentsOnly() throws {
        let background = hookEvent(.subagentStart, at: 1) { $0.agentID = "bg1"; $0.agentType = "general-purpose" }
        let stopped = hookEvent(.subagentStart, at: 2) { $0.agentID = "bg2"; $0.agentType = "general-purpose" }
        let foreground = hookEvent(.subagentStart, at: 3) { $0.agentID = "fg1"; $0.agentType = "Explore" }
        let stop = hookEvent(.stop, at: 30) { $0.backgroundAgentIDs = ["bg1"] }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 0), background, stopped, foreground, stop]))
        #expect(session.agents.map(\.id) == ["bg1"])
    }

    @Test func stopWithoutTheListKeepsAgents() throws {
        let agent = hookEvent(.subagentStart, at: 1) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 0), agent, hookEvent(.stop, at: 30)]))
        #expect(session.agents.map(\.id) == ["a1"])
    }

    @Test func aQuickReplyStartsNewWork() throws {
        // The user answered 20 s after the Stop: a new piece of work, not the previous one continued.
        let session = try #require(SessionReducer.reduce([
            start, hookEvent(.userPromptSubmit, at: 10), hookEvent(.stop, at: 60), hookEvent(.userPromptSubmit, at: 80),
        ]))
        #expect(session.workStartedAt == fixedNow.addingTimeInterval(80))
    }

    private func edit(_ id: String?, at seconds: TimeInterval, added: Int, removed: Int, file: String = "a.swift", agent: String? = nil) -> HookEvent {
        hookEvent(.postToolUse, at: seconds) {
            $0.toolUseID = id
            $0.linesAdded = added
            $0.linesRemoved = removed
            $0.editedFile = file
            $0.agentID = agent
        }
    }

    @Test func theTickerKeepsTheLastThreeMainSteps() throws {
        let tools = (1...4).map { index in
            hookEvent(.preToolUse, at: 10 + Double(index)) { $0.action = "Read \(index).swift"; $0.toolUseID = "t\(index)" }
        }
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let agentTool = hookEvent(.preToolUse, at: 16) { $0.agentID = "a1"; $0.action = "Bash ls"; $0.toolUseID = "t9" }
        let session = try #require(SessionReducer.reduce([start, agent, hookEvent(.userPromptSubmit, at: 10)] + tools + [agentTool]))
        #expect(session.steps.map(\.action) == ["Read 2.swift", "Read 3.swift", "Read 4.swift"])
        #expect(session.steps.map(\.toolUseID) == ["t2", "t3", "t4"])
        #expect(session.steps.last?.at == fixedNow.addingTimeInterval(14))
        #expect(session.agents.first?.actionToolUseID == "t9")
    }

    @Test func aPromptClearsTheTickerAndAStopKeepsIt() throws {
        let tool = hookEvent(.preToolUse, at: 11) { $0.action = "Bash ls" }
        let base = [start, hookEvent(.userPromptSubmit, at: 10), tool, hookEvent(.stop, at: 20)]
        #expect(try #require(SessionReducer.reduce(base)).steps.map(\.action) == ["Bash ls"])
        #expect(try #require(SessionReducer.reduce(base + [hookEvent(.userPromptSubmit, at: 30)])).steps.isEmpty)
    }

    @Test func countsReachTheirStepIncludingParallelCalls() throws {
        let first = hookEvent(.preToolUse, at: 11) { $0.action = "Edit a.swift"; $0.toolUseID = "t1" }
        let second = hookEvent(.preToolUse, at: 11.5) { $0.action = "Edit b.swift"; $0.toolUseID = "t2" }
        let session = try #require(SessionReducer.reduce([
            start, hookEvent(.userPromptSubmit, at: 10), first, second,
            edit("t2", at: 12, added: 3, removed: 1, file: "b.swift"),
            edit("t1", at: 13, added: 5, removed: 0),
        ]))
        #expect(session.steps.map(\.lines) == [LineCounts(added: 5, removed: 0), LineCounts(added: 3, removed: 1)])
    }

    @Test func countsReachTheirStepWhenLinesArriveOutOfOrder() throws {
        // Async hooks may write the PostToolUse line first; the event times still order them.
        let tool = hookEvent(.preToolUse, at: 11) { $0.action = "Edit a.swift"; $0.toolUseID = "t1" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), edit("t1", at: 12, added: 2, removed: 1), tool]))
        #expect(session.steps.last?.lines == LineCounts(added: 2, removed: 1))
    }

    @Test func anAgentsActionCarriesItsCountsUntilItsNextStep() throws {
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let tool = hookEvent(.preToolUse, at: 6) { $0.agentID = "a1"; $0.action = "Edit x.swift"; $0.toolUseID = "t1" }
        let edited = [start, agent, tool, edit("t1", at: 7, added: 12, removed: 3, agent: "a1")]
        let session = try #require(SessionReducer.reduce(edited))
        #expect(session.agents.first?.actionLines == LineCounts(added: 12, removed: 3))
        #expect(session.steps.isEmpty)
        let next = hookEvent(.preToolUse, at: 8) { $0.agentID = "a1"; $0.action = "Read y.swift"; $0.toolUseID = "t2" }
        #expect(try #require(SessionReducer.reduce(edited + [next])).agents.first?.actionLines == nil)
    }

    @Test func theTurnSumsMainAndAgentEditsByFile() throws {
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let session = try #require(SessionReducer.reduce([
            start, hookEvent(.userPromptSubmit, at: 1), agent,
            edit("t1", at: 10, added: 5, removed: 2, file: "a.swift"),
            edit("t2", at: 11, added: 1, removed: 0, file: "a.swift"),
            edit("t3", at: 12, added: 0, removed: 4, file: "b.swift", agent: "a1"),
            // A step that already left the ticker, or an event without an ID, still counts.
            edit("gone", at: 13, added: 2, removed: 2, file: "c.swift"),
            edit(nil, at: 14, added: 1, removed: 0, file: "c.swift"),
        ]))
        #expect(session.turn == TurnEdits(startedAt: fixedNow.addingTimeInterval(1), edits: 5, added: 9, removed: 8, files: ["a.swift", "b.swift", "c.swift"]))
    }

    @Test func aPromptOrANewSessionStartsANewTurnButCompactionDoesNot() throws {
        let before = [start, hookEvent(.userPromptSubmit, at: 1), edit("t1", at: 10, added: 5, removed: 2)]
        let compacted = try #require(SessionReducer.reduce(before + [hookEvent(.preCompact, at: 20), hookEvent(.sessionStart, at: 30) { $0.source = "compact" }]))
        #expect(compacted.turn.added == 5)
        // A background agent's edit after the Stop still belongs to the turn.
        let afterStop = try #require(SessionReducer.reduce(before + [hookEvent(.stop, at: 20), edit("t2", at: 25, added: 1, removed: 0, agent: "bg")]))
        #expect(afterStop.turn.added == 6)
        let prompted = try #require(SessionReducer.reduce(before + [hookEvent(.userPromptSubmit, at: 40)]))
        #expect(prompted.turn == TurnEdits(startedAt: fixedNow.addingTimeInterval(40)))
        for source in ["startup", "resume", "clear"] {
            let restarted = try #require(SessionReducer.reduce(before + [hookEvent(.sessionStart, at: 50) { $0.source = source }]))
            #expect(restarted.turn == TurnEdits(startedAt: fixedNow.addingTimeInterval(50)))
            #expect(restarted.steps.isEmpty)
        }
    }

    @Test func aSessionWithoutAStartBeginsItsTurnAtTheFirstEvent() throws {
        let session = try #require(SessionReducer.reduce([hookEvent(.postToolUse, at: 3), edit("t1", at: 4, added: 1, removed: 0)]))
        #expect(session.turn.startedAt == fixedNow.addingTimeInterval(3))
        #expect(session.turn.added == 1)
    }

    @Test func countsReachTheirStepWhenThePostIsStampedFirst() throws {
        // Each hook stamps its own time; a fast edit's PostToolUse hook can start a moment before the PreToolUse one.
        let agent = hookEvent(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "Explore" }
        let session = try #require(SessionReducer.reduce([
            start, agent, hookEvent(.userPromptSubmit, at: 10),
            edit("t1", at: 11.995, added: 2, removed: 1),
            hookEvent(.preToolUse, at: 12) { $0.action = "Edit a.swift"; $0.toolUseID = "t1" },
            edit("t2", at: 12.995, added: 4, removed: 0, agent: "a1"),
            hookEvent(.preToolUse, at: 13) { $0.agentID = "a1"; $0.action = "Edit b.swift"; $0.toolUseID = "t2" },
        ]))
        #expect(session.steps.last?.lines == LineCounts(added: 2, removed: 1))
        #expect(session.agents.first?.actionLines == LineCounts(added: 4, removed: 0))
        #expect(session.turn.added == 6)
    }

    @Test func earlyCountsAreBoundedAndClearedByAPrompt() throws {
        // Counts of steps that already left the ticker never find their step.
        let edits = (0..<20).map { index in edit("gone\(index)", at: 11 + Double(index), added: 1, removed: 0) }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10)] + edits))
        #expect(session.earlyLines.count == SessionReducer.maxEarlyLines)
        #expect(session.earlyLines.last?.toolUseID == "gone19")
        #expect(try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10)] + edits + [hookEvent(.userPromptSubmit, at: 40)])).earlyLines.isEmpty)
    }
}
