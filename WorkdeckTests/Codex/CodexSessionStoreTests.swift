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

    @Test func theSessionFileIsKept() throws {
        let session = try #require(SessionReducer.reduce([event(.userPromptSubmit, at: 1) { $0.transcriptPath = "/x/rollout-c1.jsonl" }]))
        #expect(session.transcriptPath == "/x/rollout-c1.jsonl")
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
