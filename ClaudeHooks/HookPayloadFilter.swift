import Foundation

/// What `workdeck-hook` keeps from a payload. `transcriptPath` only locates the agent's description and is never stored.
nonisolated struct HookPayload: Equatable, Sendable {
    var event: HookEvent
    var transcriptPath: String?
}

/// Copies an allowlist of fields from Claude Code's hook JSON. Everything else, including prompts, answers,
/// and tool input and output, is never read.
nonisolated enum HookPayloadFilter {
    static let maxFieldLength = 100

    static func parse(_ data: Data, environment: [String: String], now: Date) -> HookPayload? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (root["hook_event_name"] as? String).flatMap(HookEventName.init(rawValue:)),
              let sessionID = root["session_id"] as? String,
              isSafeIdentifier(sessionID)
        else { return nil }
        let agentID = root["agent_id"] as? String
        if let agentID, !isSafeIdentifier(agentID) {
            return nil
        }
        let event = HookEvent(
            time: now,
            name: name,
            sessionID: sessionID,
            cwd: root["cwd"] as? String,
            projectDir: environment["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 },
            pid: environment["CLAUDE_PID"].flatMap { Int32($0) },
            entrypoint: short(environment["CLAUDE_CODE_ENTRYPOINT"]),
            hostBundleID: short(environment["__CFBundleIdentifier"]),
            termProgram: short(environment["TERM_PROGRAM"]),
            source: short(root["source"]),
            reason: short(root["reason"]),
            notificationType: short(root["notification_type"]),
            agentID: agentID,
            agentType: short(root["agent_type"])
        )
        return HookPayload(event: event, transcriptPath: root["transcript_path"] as? String)
    }

    /// Session and agent IDs become file names, so only ASCII letters, digits and hyphens are accepted.
    static func isSafeIdentifier(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func short(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return String(string.prefix(maxFieldLength))
    }
}
