import Foundation

/// Human-readable session changes for the diagnostics log: statuses, agents, sessions. Never content.
nonisolated enum SessionChangeLog {
    static func label(_ session: ClaudeSession) -> String {
        "\(session.projectName)\(session.instance.map { " [\($0)]" } ?? "") (\(session.id.prefix(8)))"
    }

    static func status(_ status: SessionStatus) -> String {
        switch status {
        case .working: "working"
        case .waiting: "waiting"
        case .idle: "idle"
        case .compacting: "compacting"
        }
    }

    static func lines(previous: [ClaudeSession], current: [ClaudeSession]) -> [String] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines: [String] = []
        for session in current {
            guard let old = before[session.id] else {
                lines.append("\(label(session)): new session, \(status(session.status))")
                continue
            }
            if old.status != session.status {
                lines.append("\(label(session)): \(status(old.status)) → \(status(session.status))")
            }
            let oldIDs = Set(old.agents.map(\.id))
            let newIDs = Set(session.agents.map(\.id))
            for agent in old.agents where !newIDs.contains(agent.id) {
                lines.append("\(label(session)): agent \(agent.type) gone")
            }
            for agent in session.agents where !oldIDs.contains(agent.id) {
                lines.append("\(label(session)): agent \(agent.type) started")
            }
        }
        let currentIDs = Set(current.map(\.id))
        for session in previous where !currentIDs.contains(session.id) {
            lines.append("\(label(session)): session gone")
        }
        return lines
    }
}
