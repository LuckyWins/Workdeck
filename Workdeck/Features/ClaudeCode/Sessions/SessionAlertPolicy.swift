import Foundation

/// Turns session transitions into notch alerts (spec §10.5). Pure.
nonisolated enum SessionAlertPolicy {
    struct Outcome: Equatable, Sendable {
        var alerts: [LimitsAlert] = []
        /// Why each finish or wait was or was not announced, for the diagnostics log.
        var notes: [String] = []
    }

    static func alerts(
        previous: [ClaudeSession],
        current: [ClaudeSession],
        notifyFinished: Bool,
        finishedAfter: TimeInterval,
        notifyNeedsYou: Bool,
        frontmostBundleID: String?
    ) -> [LimitsAlert] {
        evaluate(previous: previous, current: current, notifyFinished: notifyFinished, finishedAfter: finishedAfter, notifyNeedsYou: notifyNeedsYou, frontmostBundleID: frontmostBundleID).alerts
    }

    static func evaluate(
        previous: [ClaudeSession],
        current: [ClaudeSession],
        notifyFinished: Bool,
        finishedAfter: TimeInterval,
        notifyNeedsYou: Bool,
        frontmostBundleID: String?
    ) -> Outcome {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var outcome = Outcome()
        for session in current {
            // A session seen for the first time has no transition to report.
            guard let old = before[session.id] else { continue }
            let name = session.projectName
            let stoppedNow = (old.status == .working || old.status == .compacting)
                && session.status == .idle
                && session.lastStopAt.map { session.since == $0 } == true
            let startedWaiting = old.status != .waiting && session.status == .waiting
            guard stoppedNow || startedWaiting else { continue }
            // The user is already looking at that session's app. With several sessions in one app
            // (VS Code windows), which window is in front is unknown, so the alert shows.
            if let host = session.hostBundleID, host == frontmostBundleID,
               current.filter({ $0.hostBundleID == host }).count == 1 {
                outcome.notes.append("\(name): not shown, its app is in front")
                continue
            }
            if stoppedNow, notifyFinished, let stoppedAt = session.lastStopAt {
                // An agent stopping alone is not the finish: Claude Code re-invokes the model, and a Stop follows.
                if !session.agents.isEmpty {
                    outcome.notes.append("\(name): stopped with \(session.agents.count) agents running, waiting for them")
                } else {
                    let worked = stoppedAt.timeIntervalSince(session.workStartedAt ?? old.since)
                    let duration = SessionsText.duration(from: stoppedAt.addingTimeInterval(-worked), to: stoppedAt)
                    if worked >= finishedAfter {
                        outcome.alerts.append(.sessionFinished(project: name, worked: worked, agent: session.agent))
                        outcome.notes.append("\(name): finished after \(duration), shown")
                    } else {
                        let threshold = SessionsText.duration(from: stoppedAt.addingTimeInterval(-finishedAfter), to: stoppedAt)
                        outcome.notes.append("\(name): finished after \(duration), below \(threshold)")
                    }
                }
            }
            if startedWaiting, notifyNeedsYou {
                outcome.alerts.append(.sessionNeedsYou(project: name, agent: session.agent))
                outcome.notes.append("\(name): needs you, shown")
            }
        }
        return outcome
    }
}
