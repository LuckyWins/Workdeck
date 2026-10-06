import Foundation
import Testing
@testable import Workdeck

private func session(
    _ status: SessionStatus,
    id: String = "s1",
    since: TimeInterval,
    work: TimeInterval? = 0,
    stop: TimeInterval? = nil,
    agents: Int = 0,
    lastEvent: TimeInterval? = nil,
    host: String? = "com.microsoft.VSCode"
) -> ClaudeSession {
    var session = ClaudeSession(
        id: id,
        cwd: "/p/\(id == "s1" ? "Workdeck" : id)",
        status: status,
        since: fixedNow.addingTimeInterval(since),
        agents: (0..<agents).map { RunningAgent(id: "a\($0)", type: "Explore", startedAt: fixedNow) },
        hostBundleID: host,
        lastEventAt: fixedNow.addingTimeInterval(lastEvent ?? stop ?? since)
    )
    session.workStartedAt = work.map { fixedNow.addingTimeInterval($0) }
    session.lastStopAt = stop.map { fixedNow.addingTimeInterval($0) }
    return session
}

struct SessionAlertPolicyTests {
    private func alerts(
        _ previous: [ClaudeSession],
        _ current: [ClaudeSession],
        finished: Bool = true,
        after: TimeInterval = 600,
        needsYou: Bool = true,
        frontmost: String? = "com.apple.Terminal"
    ) -> [LimitsAlert] {
        SessionAlertPolicy.alerts(previous: previous, current: current, notifyFinished: finished, finishedAfter: after, notifyNeedsYou: needsYou, frontmostBundleID: frontmost)
    }

    @Test func longTurnFinishing() {
        let result = alerts([session(.working, since: 0)], [session(.idle, since: 900, stop: 900)])
        #expect(result == [.sessionFinished(project: "Workdeck", worked: 900)])
    }

    @Test func shortTurnIsQuiet() {
        #expect(alerts([session(.working, since: 0)], [session(.idle, since: 300, stop: 300)]).isEmpty)
    }

    @Test func idlePromptIsNotAFinish() {
        // An interrupt: idle from the idle prompt, not from Stop.
        #expect(alerts([session(.working, since: 0)], [session(.idle, since: 900, stop: nil)]).isEmpty)
    }

    @Test func compactionIsNotAFinish() {
        #expect(alerts([session(.compacting, since: 800)], [session(.working, since: 900)]).isEmpty)
    }

    @Test func workIsMeasuredFromWhenItStarted() {
        let result = alerts([session(.compacting, since: 800, work: 0)], [session(.idle, since: 900, work: 0, stop: 900)])
        #expect(result == [.sessionFinished(project: "Workdeck", worked: 900)])
    }

    @Test func withoutAWorkStartThePreviousStatusTimeCounts() {
        let result = alerts([session(.working, since: 100, work: nil)], [session(.idle, since: 900, work: nil, stop: 900)])
        #expect(result == [.sessionFinished(project: "Workdeck", worked: 800)])
    }

    @Test func needsYou() {
        #expect(alerts([session(.working, since: 0)], [session(.waiting, since: 10)]) == [.sessionNeedsYou(project: "Workdeck")])
        #expect(alerts([session(.waiting, since: 10)], [session(.waiting, since: 10)]).isEmpty)
    }

    @Test func frontmostHostIsQuiet() {
        #expect(alerts([session(.working, since: 0)], [session(.waiting, since: 10)], frontmost: "com.microsoft.VSCode").isEmpty)
    }

    @Test func firstSightingIsQuiet() {
        #expect(alerts([], [session(.idle, since: 900, stop: 900), session(.waiting, since: 10)]).isEmpty)
    }

    @Test func settingsOffAreQuiet() {
        #expect(alerts([session(.working, since: 0)], [session(.idle, since: 900, stop: 900)], finished: false).isEmpty)
        #expect(alerts([session(.working, since: 0)], [session(.waiting, since: 10)], needsYou: false).isEmpty)
    }

    @Test func aHostWithSeveralSessionsIsNotMuted() {
        // Two VS Code windows: which one is in front is unknown, so the alert shows.
        let previous = [session(.working, since: 0), session(.idle, id: "vitastir", since: 0)]
        let current = [session(.waiting, since: 10), session(.idle, id: "vitastir", since: 0)]
        #expect(alerts(previous, current, frontmost: "com.microsoft.VSCode") == [.sessionNeedsYou(project: "Workdeck")])
    }

    @Test func runningAgentsDelayTheFinish() {
        #expect(alerts([session(.working, since: 0)], [session(.idle, since: 900, stop: 900, agents: 2)]).isEmpty)
    }

    @Test func anAgentStoppingIsNotAFinish() {
        // Claude Code re-invokes the model after a background agent; the Stop that follows is the finish.
        let previous = [session(.idle, since: 900, stop: 900, agents: 1)]
        let current = [session(.idle, since: 900, stop: 900, lastEvent: 1500)]
        #expect(alerts(previous, current).isEmpty)
    }

    @Test func theFinishAfterBackgroundAgentsCountsAllTheWork() {
        let previous = [session(.working, since: 1501, work: 0)]
        let current = [session(.idle, since: 1520, work: 0, stop: 1520)]
        #expect(alerts(previous, current) == [.sessionFinished(project: "Workdeck", worked: 1520)])
    }
}
