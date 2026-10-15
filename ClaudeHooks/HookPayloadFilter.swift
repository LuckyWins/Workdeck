import Foundation

/// What `workdeck-hook` keeps from a payload. For Claude Code, `transcriptPath` only locates the agent's description and is
/// never stored; for Codex, the session file's path is kept so the app can count its patches, and `model` names a new
/// agent's model (Claude's comes from the agent's `meta.json`).
nonisolated struct HookPayload: Equatable, Sendable {
    var event: HookEvent
    var transcriptPath: String?
    var model: String?
}

/// Copies an allowlist of fields from Claude Code's hook JSON. Everything else, including prompts, answers, and tool
/// input and output, is never stored: from tool input only the action summary and an edit's file name, from an edit's
/// response only its line counts.
nonisolated enum HookPayloadFilter {
    static let maxFieldLength = 100
    static let maxActionLength = 30

    /// The tool and a short target (spec §10.1); the rest of the tool input is never read.
    static func action(toolName: String, input: [String: Any]?) -> String {
        // Codex's agent tools: a launch reads like Claude's ("Agent …"), so the ticker hides it behind the agent card.
        if toolName == "collaborationspawn_agent" {
            return truncated(firstLine(input?["task_name"]).map { "Agent " + $0 } ?? "Agent")
        }
        if toolName == "collaborationwait_agent" {
            return "Waiting for agent"
        }
        if toolName.hasPrefix("mcp__") {
            let server = toolName.components(separatedBy: "__").dropFirst().first ?? ""
            return truncated(server.isEmpty ? "mcp" : "mcp:\(server)")
        }
        let target: String? = switch toolName {
        case "Read", "Edit", "MultiEdit", "Write": fileName(input?["file_path"])
        case "NotebookEdit": fileName(input?["notebook_path"])
        case "Bash": firstLine(input?["command"]).map(maskingSecrets)
        case "WebFetch": (input?["url"] as? String).flatMap { URL(string: $0)?.host() }
        case "WebSearch": firstLine(input?["query"])
        case "Grep", "Glob": firstLine(input?["pattern"])
        case "Agent", "Task": firstLine(input?["subagent_type"])
        default: nil
        }
        return truncated([toolName, target].compactMap { $0 }.joined(separator: " "))
    }

    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write"]

    /// Lines an applied edit added and removed, from Claude Code's `tool_response` (spec §2.1): the `+` and `-` lines
    /// of its patch, or every line of a file `Write` created. The text is only counted, never kept.
    static func lineCounts(toolName: String, response: [String: Any]?) -> LineCounts? {
        guard editTools.contains(toolName), let response else { return nil }
        if let patch = response["structuredPatch"] as? [[String: Any]], !patch.isEmpty {
            var counts = LineCounts(added: 0, removed: 0)
            for hunk in patch {
                guard let lines = hunk["lines"] as? [String] else { return nil }
                for line in lines {
                    if line.hasPrefix("+") {
                        counts.added += 1
                    } else if line.hasPrefix("-") {
                        counts.removed += 1
                    }
                }
            }
            return counts
        }
        if toolName == "Write", response["type"] as? String == "create", let content = response["content"] as? String {
            return LineCounts(added: lineCount(content), removed: 0)
        }
        return nil
    }

    /// "a\nb\n" and "a\nb" are two lines, "" none. Bytes, not characters: "\r\n" is one character.
    static func lineCount(_ text: String) -> Int {
        let newline = UInt8(ascii: "\n")
        let breaks = text.utf8.reduce(0) { $0 + ($1 == newline ? 1 : 0) }
        guard let last = text.utf8.last else { return 0 }
        return last == newline ? breaks : breaks + 1
    }

    /// Tool call IDs such as `toolu_01AbC…`.
    static func isSafeToolUseID(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func fileName(_ value: Any?) -> String? {
        guard let path = value as? String else { return nil }
        let name = URL(filePath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// The first line with runs of whitespace collapsed.
    private static func firstLine(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let line = string.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Hides values that look like secrets in a shell command: `NAME=value`, `-pPASSWORD`, `Bearer TOKEN`.
    static func maskingSecrets(_ command: String) -> String {
        let rules: [(pattern: String, template: String)] = [
            (#"\b([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'[^']*'|[^\s'"]+)"#, "$1=…"),
            (#"(^|\s)-p[^\s'"]+"#, "$1-p…"),
            (#"(?i)\b(bearer|basic|token)\s+[^\s'"]+"#, "$1 …"),
        ]
        var result = command
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.template)
        }
        return result
    }

    private static func truncated(_ text: String) -> String {
        text.count <= maxActionLength ? text : String(text.prefix(maxActionLength - 1)) + "…"
    }

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
        var event = HookEvent(
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
        if name == .preToolUse, let tool = root["tool_name"] as? String {
            event.action = action(toolName: String(tool.prefix(maxFieldLength)), input: root["tool_input"] as? [String: Any])
        }
        if name == .preToolUse || name == .postToolUse, let id = root["tool_use_id"] as? String, isSafeToolUseID(id) {
            event.toolUseID = id
        }
        if name == .postToolUse, let tool = root["tool_name"] as? String,
           let counts = lineCounts(toolName: tool, response: root["tool_response"] as? [String: Any]) {
            event.linesAdded = counts.added
            event.linesRemoved = counts.removed
            event.editedFile = fileName((root["tool_input"] as? [String: Any])?["file_path"]).map { String($0.prefix(maxFieldLength)) }
        }
        if name == .stop, agentID == nil, let tasks = root["background_tasks"] as? [[String: Any]] {
            event.backgroundAgentIDs = tasks
                .filter { $0["type"] as? String == "subagent" }
                .compactMap { $0["id"] as? String }
                .filter(isSafeIdentifier)
        }
        return HookPayload(event: event, transcriptPath: root["transcript_path"] as? String, model: short(root["model"]))
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
