import Foundation
import Testing
@testable import Workdeck

@MainActor
struct CodexSessionStoreTests {
    private func event(_ name: HookEventName, at seconds: TimeInterval, session: String = "c1", configure: (inout HookEvent) -> Void = { _ in }) -> HookEvent {
        hookEvent(name, at: seconds, session: session, configure: configure)
    }

    @Test func aPermissionRequestWaitsUntilTheNextEvent() throws {
        let session = try #require(SessionReducer.reduce([
            event(.sessionStart, at: 0) { $0.cwd = "/p/docs" },
            event(.userPromptSubmit, at: 1),
            event(.preToolUse, at: 2) { $0.action = "Bash curl -sI x"; $0.toolUseID = "call_1" },
            event(.permissionRequest, at: 3),
        ]))
        #expect(session.status == .waiting)
        let resumed = SessionReducer.apply(event(.postToolUse, at: 9) { $0.toolUseID = "call_1" }, to: session)
        #expect(resumed.status == .working)
    }

    @Test func anInterruptEndsTheTurn() throws {
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.preToolUse, at: 2) { $0.action = "Bash ls" },
            event(.interrupt, at: 3),
        ]))
        #expect(session.status == .idle)
        #expect(session.action == nil)
    }

    @Test func anOldEventWithASessionFileStillReads() throws {
        let json = #"{"time":0,"name":"UserPromptSubmit","sessionID":"c1","transcriptPath":"/x/rollout-c1.jsonl"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        let session = try #require(SessionReducer.reduce([event]))
        #expect(session.status == .working)
    }

    @Test func aPatchCountsOnItsStepAndInTheTurn() throws {
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.preToolUse, at: 2) { $0.action = "Edit 2 files"; $0.toolUseID = "call_1" },
            event(.postToolUse, at: 3) { $0.toolUseID = "call_1"; $0.linesAdded = 3; $0.linesRemoved = 1; $0.editedFiles = ["App.swift", "notes.md"] },
        ]))
        #expect(session.steps.last?.lines == LineCounts(added: 3, removed: 1))
        #expect(session.turn.edits == 1)
        #expect(session.turn.added == 3 && session.turn.removed == 1)
        #expect(session.turn.files == ["App.swift", "notes.md"])
    }

    @Test func anAgentsPatchShowsOnItsRow() throws {
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.subagentStart, at: 2) { $0.agentID = "a1"; $0.agentType = "default" },
            event(.preToolUse, at: 3) { $0.agentID = "a1"; $0.action = "Edit App.swift"; $0.toolUseID = "call_2" },
            event(.postToolUse, at: 4) { $0.agentID = "a1"; $0.toolUseID = "call_2"; $0.linesAdded = 2; $0.linesRemoved = 0; $0.editedFiles = ["App.swift"] },
        ]))
        #expect(session.agents.first?.actionLines == LineCounts(added: 2, removed: 0))
        #expect(session.turn.files == ["App.swift"])
    }

    @Test func spawnNamesGoToAgentsInOrder() throws {
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.preToolUse, at: 2) { $0.action = "Agent count_swift"; $0.toolUseID = "call_1" },
            event(.postToolUse, at: 2.1) { $0.agentTaskName = "count_swift"; $0.toolUseID = "call_1" },
            event(.preToolUse, at: 3) { $0.action = "Agent count_docs"; $0.toolUseID = "call_2" },
            event(.postToolUse, at: 3.1) { $0.agentTaskName = "count_docs"; $0.toolUseID = "call_2" },
            event(.subagentStart, at: 4) { $0.agentID = "a1"; $0.agentType = "default" },
            event(.subagentStart, at: 5) { $0.agentID = "a2"; $0.agentType = "default" },
        ]))
        #expect(session.agents.map(\.description) == ["count_swift", "count_docs"])
        #expect(session.pendingAgentNames.isEmpty)
    }

    @Test func aFailedSpawnNamesNoAgent() throws {
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.preToolUse, at: 2) { $0.action = "Agent refused_one"; $0.toolUseID = "call_1" },
            event(.postToolUse, at: 2.1) { $0.toolUseID = "call_1" },
            event(.preToolUse, at: 3) { $0.action = "Agent count_docs"; $0.toolUseID = "call_2" },
            event(.postToolUse, at: 3.1) { $0.agentTaskName = "count_docs"; $0.toolUseID = "call_2" },
            event(.subagentStart, at: 4) { $0.agentID = "a1"; $0.agentType = "default" },
        ]))
        #expect(session.agents.first?.description == "count_docs")
    }

    @Test func aPromptDropsWaitingNames() throws {
        for end in [HookEventName.userPromptSubmit, .stop, .interrupt] {
            let session = try #require(SessionReducer.reduce([
                event(.userPromptSubmit, at: 1),
                event(.postToolUse, at: 2) { $0.agentTaskName = "never_started"; $0.toolUseID = "call_1" },
                event(end, at: 3),
                event(.userPromptSubmit, at: 4),
                event(.subagentStart, at: 5) { $0.agentID = "a1"; $0.agentType = "default" },
            ]))
            #expect(session.agents.first?.description == nil)
        }
    }

    @Test func codexSessionsShareAProcess() {
        let directory = makeTemporaryDirectory()
        let liveness = FakeLiveness()
        liveness.startTimes[77] = fixedNow.addingTimeInterval(-60)
        for id in ["c1", "c2"] {
            writeSessionEvent(event(.sessionStart, at: 0, session: id) { $0.pid = 77; $0.cwd = "/p/\(id)" }, to: directory)
            writeSessionEvent(event(.userPromptSubmit, at: 1, session: id), to: directory)
        }
        let store = ClaudeSessionStore(directory: directory, liveness: liveness, agent: .codex, oneSessionPerProcess: false) { fixedNow.addingTimeInterval(2) }
        store.reload()
        #expect(Set(store.sessions.map(\.id)) == ["c1", "c2"])
        #expect(store.sessions.allSatisfy { $0.agent == .codex })
        // Claude's rule stays: one process, one session.
        let claude = ClaudeSessionStore(directory: directory, liveness: liveness) { fixedNow.addingTimeInterval(2) }
        claude.reload()
        #expect(claude.sessions.count == 1)
    }

    @Test func aSilentCodexSessionGoesIdleThenAway() {
        let directory = makeTemporaryDirectory()
        let liveness = FakeLiveness()
        liveness.startTimes[77] = fixedNow.addingTimeInterval(-60)
        writeSessionEvent(event(.sessionStart, at: 0) { $0.pid = 77; $0.cwd = "/p/docs" }, to: directory)
        writeSessionEvent(event(.userPromptSubmit, at: 1), to: directory)
        let now = Box(fixedNow.addingTimeInterval(31 * 60))
        let store = ClaudeSessionStore(directory: directory, liveness: liveness, agent: .codex, oneSessionPerProcess: false) { now.value }
        store.reload()
        // The app-server outlives a chat closed mid-turn: silence ends the work.
        #expect(store.sessions.map(\.status) == [.idle])
        now.value = fixedNow.addingTimeInterval(3 * 3600 + 120)
        store.reload()
        #expect(store.sessions.isEmpty)
    }

    @Test func claudeSessionsKeepTheirStateThroughSilence() {
        let directory = makeTemporaryDirectory()
        let liveness = FakeLiveness()
        liveness.startTimes[77] = fixedNow.addingTimeInterval(-60)
        writeSessionEvent(event(.sessionStart, at: 0) { $0.pid = 77; $0.cwd = "/p/docs" }, to: directory)
        writeSessionEvent(event(.userPromptSubmit, at: 1), to: directory)
        let store = ClaudeSessionStore(directory: directory, liveness: liveness) { fixedNow.addingTimeInterval(31 * 60) }
        store.reload()
        #expect(store.sessions.map(\.status) == [.working])
    }

    @Test func anInterruptDropsForegroundAgents() throws {
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.subagentStart, at: 2) { $0.agentID = "a1"; $0.agentType = "default" },
            event(.interrupt, at: 3),
        ]))
        #expect(session.agents.isEmpty)
    }

    @Test func theAskingAgentsNextCallEndsTheWait() throws {
        // Codex calls a tool only after the request was answered; a denial sends no PostToolUse.
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.preToolUse, at: 2) { $0.action = "Bash curl -sI x"; $0.toolUseID = "call_1" },
            event(.permissionRequest, at: 3) { $0.agentID = "a1" },
            event(.preToolUse, at: 4) { $0.action = "Bash ls"; $0.toolUseID = "call_2" },
        ]))
        #expect(session.status == .waiting)
        let resumed = SessionReducer.apply(event(.preToolUse, at: 9) { $0.agentID = "a1"; $0.action = "Bash ls"; $0.toolUseID = "call_3" }, to: session)
        #expect(resumed.status == .working)
    }

    @Test func claudeKeepsWaitingThroughAParallelCall() throws {
        let session = try #require(SessionReducer.reduce([
            event(.userPromptSubmit, at: 1),
            event(.preToolUse, at: 2) { $0.action = "Bash rm x"; $0.toolUseID = "t1" },
            event(.notification, at: 3) { $0.notificationType = "permission_prompt" },
            event(.preToolUse, at: 4) { $0.action = "Read a.md"; $0.toolUseID = "t2" },
        ]))
        #expect(session.status == .waiting)
    }
}
