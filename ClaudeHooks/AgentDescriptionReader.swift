import Foundation

/// Claude Code writes each subagent's task description, model alias and request shape to an undocumented
/// `meta.json` next to the transcript,
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

    /// The agent's description, model alias and whether it runs in the background; `nil` when the file
    /// never appears or is not JSON.
    static func meta(
        at url: URL,
        attempts: Int = 5,
        delay: TimeInterval = 0.2,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> AgentMeta? {
        for attempt in 0..<attempts {
            if let data = try? Data(contentsOf: url) {
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                let description = (root["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let model = (root["model"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(HookPayloadFilter.maxFieldLength)) }
                return AgentMeta(
                    description: description.flatMap { $0.isEmpty ? nil : String($0.prefix(maxLength)) },
                    model: model,
                    isBackground: root["requestShape"] as? String == "background"
                )
            }
            if attempt < attempts - 1 {
                sleep(delay)
            }
        }
        return nil
    }

    /// The agent's own transcript, next to its `meta.json`.
    static func transcriptURL(forMeta url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
    }
}

/// What `meta.json` says about a subagent.
nonisolated struct AgentMeta: Equatable, Sendable {
    var description: String?
    /// A short alias such as "opus"; the full model ID is in the agent's transcript.
    var model: String?
    var isBackground: Bool
}
