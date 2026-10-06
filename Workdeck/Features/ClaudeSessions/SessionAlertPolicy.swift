import Foundation

/// Turns session transitions into notch alerts (spec §10.5). Pure.
nonisolated enum SessionAlertPolicy {
    static func alerts(
        previous: [ClaudeSession],
        current: [ClaudeSession],
        notifyFinished: Bool,
        finishedAfter: TimeInterval,
        notifyNeedsYou: Bool,
        frontmostBundleID: String?
    ) -> [LimitsAlert] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var alerts: [LimitsAlert] = []
        for session in current {
            // A session seen for the first time has no transition to report.
            guard let old = before[session.id] else { continue }
            // The user is already looking at that session's app. With several sessions in one app
            // (VS Code windows), which window is in front is unknown, so the alert shows.
            if let host = session.hostBundleID, host == frontmostBundleID,
               current.filter({ $0.hostBundleID == host }).count == 1 {
                continue
            }
            if notifyFinished,
               old.status == .working || old.status == .compacting,
               session.status == .idle,
               let stoppedAt = session.lastStopAt,
               session.since == stoppedAt {
                let worked = stoppedAt.timeIntervalSince(session.turnStartedAt ?? old.since)
                if worked >= finishedAfter {
                    alerts.append(.sessionFinished(project: session.projectName, worked: worked))
                }
            }
            if notifyNeedsYou, old.status != .waiting, session.status == .waiting {
                alerts.append(.sessionNeedsYou(project: session.projectName))
            }
        }
        return alerts
    }
}
