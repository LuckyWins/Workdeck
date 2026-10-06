import Foundation

/// Claude Code writes each subagent's task description to an undocumented `meta.json` next to the transcript,
/// in the same second as `SubagentStart`, so the hook waits briefly for it.
nonisolated enum AgentDescriptionReader {
    static let maxLength = 80

    static func metaURL(transcriptPath: String, sessionID: String, agentID: String) -> URL {
        URL(filePath: transcriptPath)
            .deletingLastPathComponent()
            .appending(path: sessionID)
            .appending(path: "subagents")
            .appending(path: "agent-\(agentID).meta.json")
    }

    static func description(
        at url: URL,
        attempts: Int = 5,
        delay: TimeInterval = 0.2,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> String? {
        for attempt in 0..<attempts {
            if let data = try? Data(contentsOf: url) {
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let description = (root["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !description.isEmpty
                else { return nil }
                return String(description.prefix(maxLength))
            }
            if attempt < attempts - 1 {
                sleep(delay)
            }
        }
        return nil
    }
}
