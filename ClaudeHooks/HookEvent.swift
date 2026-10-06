import Foundation

/// The Claude Code hook events Workdeck subscribes to.
nonisolated enum HookEventName: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case postToolUse = "PostToolUse"
    case notification = "Notification"
    case stop = "Stop"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case preToolUse = "PreToolUse"
    case preCompact = "PreCompact"
}

/// One line of a session's event file. Holds only what Workdeck needs, never prompt, answer, or tool content.
nonisolated struct HookEvent: Codable, Equatable, Sendable {
    var time: Date
    var name: HookEventName
    var sessionID: String
    /// Claude's current directory, which follows `cd` in the Bash tool.
    var cwd: String?
    /// `CLAUDE_PROJECT_DIR`: the project the session was started in.
    var projectDir: String?
    /// `CLAUDE_PID`: the `claude` process running the session.
    var pid: Int32?
    /// `CLAUDE_CODE_ENTRYPOINT`, e.g. `cli` or `claude-vscode`.
    var entrypoint: String?
    /// `__CFBundleIdentifier` of the app hosting the session, e.g. `com.microsoft.VSCode`.
    var hostBundleID: String?
    var termProgram: String?
    var source: String?
    var reason: String?
    var notificationType: String?
    var agentID: String?
    var agentType: String?
    var agentDescription: String?
    /// `PreToolUse` only: the tool and a short target, e.g. "Read NotchPresenter.swift".
    var action: String?
}
