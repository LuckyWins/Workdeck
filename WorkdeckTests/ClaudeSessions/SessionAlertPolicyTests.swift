import Foundation
import Testing
@testable import Workdeck

private func session(
    _ status: SessionStatus,
    id: String = "s1",
    since: TimeInterval,
    turn: TimeInterval? = 0,
    stop: TimeInterval? = nil,
    host: String? = "com.microsoft.VSCode"
) -> ClaudeSession {
    var session = ClaudeSession(id: id, cwd: "/p/\(id == "s1" ? "Workdeck" : id)", status: status, since: fixedNow.addingTimeInterval(since), hostBundleID: host, lastEventAt: fixedNow)
    session.turnStartedAt = turn.map { fixedNow.addingTimeInterval($0) }
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

    @Test func turnStartIsMeasuredFromThePrompt() {
        let result = alerts([session(.compacting, since: 800, turn: 0)], [session(.idle, since: 900, turn: 0, stop: 900)])
        #expect(result == [.sessionFinished(project: "Workdeck", worked: 900)])
    }

    @Test func withoutATurnStartThePreviousStatusTimeCounts() {
        let result = alerts([session(.working, since: 100, turn: nil)], [session(.idle, since: 900, turn: nil, stop: 900)])
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
}
