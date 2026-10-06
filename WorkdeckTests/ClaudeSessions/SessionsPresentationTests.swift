import Foundation
import Testing
@testable import Workdeck

private func session(_ id: String, _ status: SessionStatus, agents: [RunningAgent] = []) -> ClaudeSession {
    ClaudeSession(id: id, cwd: "/p/\(id)", status: status, since: fixedNow, agents: agents, lastEventAt: fixedNow)
}

private func agent(_ id: String, startedSecondsAgo: TimeInterval, description: String? = nil) -> RunningAgent {
    RunningAgent(id: id, type: "Explore", description: description, startedAt: fixedNow.addingTimeInterval(-startedSecondsAgo))
}

struct SessionsPresentationTests {
    @Test func noSessions() {
        let state = SessionsPresentation.viewState(sessions: [], now: fixedNow)
        #expect(state == SessionsViewState(now: fixedNow))
        #expect(state.level == .none)
    }

    @Test func levelFollowsTheMostUrgentSession() {
        #expect(SessionsPresentation.viewState(sessions: [session("a", .idle)], now: fixedNow).level == .idle)
        #expect(SessionsPresentation.viewState(sessions: [session("a", .working), session("b", .idle)], now: fixedNow).level == .working)
        #expect(SessionsPresentation.viewState(sessions: [session("a", .waiting), session("b", .working)], now: fixedNow).level == .waiting)
    }

    @Test func showsAtMostThreeSessions() {
        let sessions = ["a", "b", "c", "d", "e"].map { session($0, .working) } + [session("w", .waiting)]
        let state = SessionsPresentation.viewState(sessions: sessions, now: fixedNow)
        #expect(state.rows.map(\.id) == ["a", "b", "c"])
        #expect(state.hiddenSessionCount == 3)
        #expect(state.totalCount == 6)
        #expect(state.waitingCount == 1)
    }

    @Test func showsAtMostTwoAgentsLongestRunningFirst() throws {
        let agents = [
            agent("new", startedSecondsAgo: 10),
            agent("old", startedSecondsAgo: 300, description: "Find NotchPresenter usages"),
            agent("mid", startedSecondsAgo: 60),
        ]
        let row = try #require(SessionsPresentation.viewState(sessions: [session("a", .working, agents: agents)], now: fixedNow).rows.first)
        #expect(row.agents.map(\.id) == ["old", "mid"])
        #expect(row.agents.map(\.title) == ["Explore · Find NotchPresenter usages", "Explore"])
        #expect(row.hiddenAgentCount == 1)
        #expect(row.projectName == "a")
    }
}

struct SessionsTextTests {
    @Test func statusTexts() {
        #expect(SessionsText.statusText(.working) == "working")
        #expect(SessionsText.statusText(.waiting) == "waiting for you")
        #expect(SessionsText.statusText(.idle) == "idle")
    }

    @Test(arguments: [(-5.0, "<1m"), (30.0, "<1m"), (720.0, "12m"), (3900.0, "1h 5m"), (10800.0, "3h")])
    func durations(seconds: TimeInterval, expected: String) {
        #expect(SessionsText.duration(from: fixedNow, to: fixedNow.addingTimeInterval(seconds)) == expected)
    }

    @Test func summaries() {
        #expect(SessionsText.summary(SessionsViewState()) == "no sessions")
        #expect(SessionsText.summary(SessionsViewState(totalCount: 1)) == "1 session")
        #expect(SessionsText.summary(SessionsViewState(totalCount: 3, waitingCount: 1)) == "3 sessions, 1 waiting")
    }

    @Test func moreTexts() {
        #expect(SessionsText.moreSessions(2) == "+2 more")
        #expect(SessionsText.moreAgents(1) == "+1 agent")
        #expect(SessionsText.moreAgents(3) == "+3 agents")
    }
}
