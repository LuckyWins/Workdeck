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
        let idlePrompt = hookEvent(.notification, at: 20) { $0.notificationType = "idle_prompt" }
        let session = try #require(SessionReducer.reduce([start, hookEvent(.userPromptSubmit, at: 10), idlePrompt]))
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
}
