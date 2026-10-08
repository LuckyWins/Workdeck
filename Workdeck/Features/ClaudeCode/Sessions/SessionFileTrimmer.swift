import Foundation

/// Keeps a session's event file small (spec §15): above `maxFileSize` it is cut to about `keptFileSize` of its
/// newest events, plus the older events that still shape the session, so a relaunch rebuilds the same session.
nonisolated enum SessionFileTrimmer {
    static let maxFileSize = 1_000_000
    static let keptFileSize = 500_000

    /// The newest lines that fit in `tailSize`, preceded by the older lines still needed: the session's start, the
    /// events that first reported its process, set its current status and started its current work, and each running
    /// agent's start and latest event.
    static func kept(_ lines: [Data], session: ClaudeSession, tailSize: Int) -> [Data] {
        var cut = lines.count
        var size = 0
        while cut > 0, size + lines[cut - 1].count <= tailSize {
            cut -= 1
            size += lines[cut].count
        }
        let running = Set(session.agents.map(\.id))
        let workStart = session.isBusy ? session.workStartedAt : nil
        let decoder = HookEventFile.decoder()
        var start: Int?
        var needed = Set<Int>()
        var agentStarts: [String: Int] = [:]
        var agentLatest: [String: Int] = [:]
        for index in 0..<cut {
            guard let event = try? decoder.decode(HookEvent.self, from: lines[index]) else { continue }
            if event.name == .sessionStart, event.source != "compact" {
                start = index
            }
            if event.time == session.pidSince || event.time == session.since || event.time == workStart {
                needed.insert(index)
            }
            if let agentID = event.agentID, running.contains(agentID) {
                if event.name == .subagentStart {
                    agentStarts[agentID] = index
                }
                agentLatest[agentID] = index
            }
        }
        if let start {
            needed.insert(start)
        }
        needed.formUnion(agentStarts.values)
        needed.formUnion(agentLatest.values)
        return needed.sorted().map { lines[$0] } + lines[cut...]
    }
}
