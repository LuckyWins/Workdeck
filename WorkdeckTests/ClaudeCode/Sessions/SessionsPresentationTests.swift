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

    @Test func countsEveryRunningAgent() {
        let busy = session("a", .working, agents: [agent("1", startedSecondsAgo: 1), agent("2", startedSecondsAgo: 2), agent("3", startedSecondsAgo: 3)])
        let sessions = [busy, session("b", .working, agents: [agent("4", startedSecondsAgo: 1)]), session("c", .idle), session("d", .idle, agents: [agent("5", startedSecondsAgo: 1)])]
        let state = SessionsPresentation.viewState(sessions: sessions, now: fixedNow)
        #expect(state.agentCount == 5)
        #expect(SessionsPresentation.viewState(sessions: [], now: fixedNow).agentCount == 0)
    }

    @Test func compactingCountsAsWorking() {
        #expect(SessionsPresentation.viewState(sessions: [session("a", .compacting), session("b", .idle)], now: fixedNow).level == .working)
    }

    @Test func rowsCarryActions() throws {
        var main = session("a", .working, agents: [RunningAgent(id: "x", type: "Explore", description: "Find", startedAt: fixedNow, action: "Read y.swift")])
        main.action = "Bash ls"
        let row = try #require(SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first)
        #expect(row.action == "Bash ls")
        #expect(row.agents.first?.action == "Read y.swift")
        #expect(row.agents.first?.description == "Find")
    }

    @Test func countsOnlyActiveSessions() {
        let state = SessionsPresentation.viewState(
            sessions: [session("a", .working), session("b", .idle), session("c", .waiting), session("d", .compacting), session("e", .idle)],
            now: fixedNow
        )
        #expect(state.activeCount == 3)
        #expect(state.totalCount == 5)
        #expect(SessionsPresentation.viewState(sessions: [session("a", .idle)], now: fixedNow).activeCount == 0)
    }

    @Test func agentRowsCarryModelBackgroundAndSteps() throws {
        var resolved = RunningAgent(id: "x", type: "general-purpose", startedAt: fixedNow)
        resolved.model = "opus"
        resolved.modelID = "claude-opus-5-5"
        resolved.isBackground = true
        resolved.steps = 87
        var alias = RunningAgent(id: "y", type: "Explore", startedAt: fixedNow.addingTimeInterval(1))
        alias.model = "haiku"
        let row = try #require(SessionsPresentation.viewState(sessions: [session("a", .working, agents: [resolved, alias])], now: fixedNow).rows.first)
        #expect(row.agents.map(\.model) == ["Opus 5.5", "Haiku"])
        #expect(row.agents.map(\.isBackground) == [true, false])
        #expect(row.agents.map(\.steps) == [87, 0])
    }

    @Test func agentLinesNameTheTaskAndHideBuiltInTypes() throws {
        let research = RunningAgent(id: "a", type: "general-purpose", description: "Authorize.Net refund research", startedAt: fixedNow, action: "Bash cd /x")
        let review = RunningAgent(id: "b", type: "code-reviewer", description: "Review auth module", startedAt: fixedNow.addingTimeInterval(1))
        let unnamed = RunningAgent(id: "c", type: "code-reviewer", startedAt: fixedNow.addingTimeInterval(2))
        let rows = SessionsPresentation.viewState(sessions: [session("s", .working, agents: [research, review, unnamed])], now: fixedNow).rows
        let agents = try #require(rows.first?.agents)
        #expect(agents[0].name == "Authorize.Net refund research")
        #expect(agents[0].customType == nil)
        #expect(agents[0].detail == "Bash cd /x")
        #expect(agents[1].name == "Review auth module")
        #expect(agents[1].customType == "code-reviewer")
        #expect(agents[1].detail == "starting…")
        #expect(SessionsPresentation.builtInAgentTypes == ["general-purpose", "Explore", "Plan"])
    }

    @Test func anAgentWithoutADescriptionIsNamedByItsType() throws {
        let unnamed = RunningAgent(id: "c", type: "code-reviewer", startedAt: fixedNow)
        let agent = try #require(SessionsPresentation.viewState(sessions: [session("s", .working, agents: [unnamed])], now: fixedNow).rows.first?.agents.first)
        #expect(agent.name == "code-reviewer")
        #expect(agent.customType == nil)
    }

    @Test func focusIsTheFirstWorkingSessionWhateverActedLast() {
        // Display order: waiting first, then working sessions with the most recent start first.
        var first = session("a", .working)
        first.steps = [SessionStep(toolUseID: "t1", action: "Read x.swift", at: fixedNow)]
        var second = session("b", .working)
        second.steps = [SessionStep(toolUseID: "t2", action: "Bash ls", at: fixedNow.addingTimeInterval(5))]
        let state = SessionsPresentation.viewState(sessions: [session("w", .waiting), first, second], now: fixedNow)
        #expect(state.rows.map(\.isFocused) == [false, true, false])
        #expect(state.rows.map { $0.steps.map(\.action) } == [[], ["Read x.swift"], []])
    }

    @Test func compactingCanBeFocusedIdleAndWaitingCannot() {
        #expect(SessionsPresentation.viewState(sessions: [session("a", .compacting)], now: fixedNow).rows.map(\.isFocused) == [true])
        #expect(SessionsPresentation.viewState(sessions: [session("w", .waiting), session("i", .idle)], now: fixedNow).rows.map(\.isFocused) == [false, false])
    }

    @Test func tickerStepsAgeFromTheCurrentOne() throws {
        var main = session("a", .working)
        main.steps = [
            SessionStep(toolUseID: "t1", action: "Read x.swift", at: fixedNow),
            SessionStep(toolUseID: "t2", action: "Edit x.swift", lines: LineCounts(added: 6, removed: 2), at: fixedNow.addingTimeInterval(1)),
            SessionStep(toolUseID: nil, action: "Bash ls", at: fixedNow.addingTimeInterval(2)),
        ]
        let steps = try #require(SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first?.steps)
        #expect(steps.map(\.age) == [2, 1, 0])
        // Earlier steps share the faintest shade, so they never match an agent's current action.
        #expect(steps.map(\.opacity) == [0.25, 0.25, 1])
        #expect(steps.map(\.lines) == [nil, LineCounts(added: 6, removed: 2), nil])
        #expect(steps.map(\.id) == ["t1", "t2", "\(fixedNow.addingTimeInterval(2).timeIntervalSince1970) Bash ls"])
    }

    @Test func agentLaunchesStayOutOfTheTickerAndMarkNoStepCurrent() throws {
        // The agent card shows the launched agent; a "▸ Agent" line would only repeat it.
        var main = session("a", .working)
        main.steps = [
            SessionStep(toolUseID: "t1", action: "Read x.swift", at: fixedNow),
            SessionStep(toolUseID: "t2", action: "Bash ls", at: fixedNow.addingTimeInterval(1)),
            SessionStep(toolUseID: "t3", action: "Agent Explore", at: fixedNow.addingTimeInterval(2)),
        ]
        let waiting = try #require(SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first?.steps)
        #expect(waiting.map(\.action) == ["Read x.swift", "Bash ls"])
        #expect(waiting.allSatisfy { $0.age > 0 && $0.opacity == 0.25 })
        // The main agent goes on (e.g. after a background agent): its new step is current again.
        main.steps = [
            SessionStep(toolUseID: "t2", action: "Bash ls", at: fixedNow.addingTimeInterval(1)),
            SessionStep(toolUseID: "t3", action: "Task", at: fixedNow.addingTimeInterval(2)),
            SessionStep(toolUseID: "t4", action: "TaskOutput", at: fixedNow.addingTimeInterval(3)),
        ]
        let goingOn = try #require(SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first?.steps)
        #expect(goingOn.map(\.action) == ["Bash ls", "TaskOutput"])
        #expect(goingOn.map(\.age) == [1, 0])
    }

    @Test func rowsAndAgentsCarryTheirActionCounts() throws {
        var agentWithEdit = RunningAgent(id: "x", type: "Explore", startedAt: fixedNow, action: "Edit y.swift")
        agentWithEdit.actionLines = LineCounts(added: 12, removed: 3)
        var main = session("a", .working, agents: [agentWithEdit])
        main.action = "Edit a.swift"
        main.steps = [SessionStep(toolUseID: "t1", action: "Edit a.swift", lines: LineCounts(added: 3, removed: 1), at: fixedNow)]
        let row = try #require(SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first)
        #expect(row.actionLines == LineCounts(added: 3, removed: 1))
        #expect(row.agents.first?.actionLines == LineCounts(added: 12, removed: 3))
        // After a Stop the action is gone, and its counts with it.
        main.action = nil
        #expect(SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first?.actionLines == nil)
    }

    @Test func theTurnLineFollowsTheStatusAndHidesWithoutEdits() {
        func turnRow(_ status: SessionStatus, edits: Int) -> TurnRow? {
            var main = session("a", status)
            main.turn = TurnEdits(startedAt: fixedNow, edits: edits, added: 84, removed: 21, files: ["a.swift", "b.swift"])
            return SessionsPresentation.viewState(sessions: [main], now: fixedNow).rows.first?.turn
        }
        let lines = LineCounts(added: 84, removed: 21)
        #expect(turnRow(.working, edits: 3) == TurnRow(isFinished: false, fileCount: 2, lines: lines))
        #expect(turnRow(.waiting, edits: 3) == TurnRow(isFinished: false, fileCount: 2, lines: lines))
        #expect(turnRow(.compacting, edits: 3) == TurnRow(isFinished: false, fileCount: 2, lines: lines))
        #expect(turnRow(.idle, edits: 3) == TurnRow(isFinished: true, fileCount: 2, lines: lines))
        #expect(turnRow(.working, edits: 0) == nil)
    }
}

struct SessionsTextTests {
    @Test func statusTexts() {
        #expect(SessionsText.statusText(.working) == "working")
        #expect(SessionsText.statusText(.waiting) == "waiting for you")
        #expect(SessionsText.statusText(.idle) == "idle")
        #expect(SessionsText.statusText(.compacting) == "compacting")
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
        #expect(SessionsText.steps(1) == "1 step")
        #expect(SessionsText.steps(87) == "87 steps")
    }

    @Test func lineCountsLeaveOutZeroParts() {
        #expect(SessionsText.added(LineCounts(added: 12, removed: 3)) == "+12")
        #expect(SessionsText.removed(LineCounts(added: 12, removed: 3)) == "\u{2212}3")
        #expect(SessionsText.added(LineCounts(added: 0, removed: 3)) == nil)
        #expect(SessionsText.removed(LineCounts(added: 4, removed: 0)) == nil)
    }

    @Test func turnTexts() {
        let lines = LineCounts(added: 1, removed: 0)
        #expect(SessionsText.turn(TurnRow(isFinished: false, fileCount: 5, lines: lines)) == "this turn · 5 files")
        #expect(SessionsText.turn(TurnRow(isFinished: true, fileCount: 1, lines: lines)) == "last turn · 1 file")
        #expect(SessionsText.turn(TurnRow(isFinished: false, fileCount: 0, lines: lines)) == "this turn")
    }
}
