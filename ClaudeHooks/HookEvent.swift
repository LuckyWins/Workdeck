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
    /// A turn cut short by an API error, e.g. a plan limit: Claude Code sends this instead of `Stop`.
    case stopFailure = "StopFailure"
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
    /// From the agent's `meta.json`: a model alias such as "opus", and whether it runs in the background.
    var agentModel: String?
    var agentBackground: Bool?
    /// Where the agent's transcript is; the app reads only the model ID from it.
    var agentTranscriptPath: String?
    /// Main `Stop` only: the background agents still running, from `background_tasks` (IDs only).
    var backgroundAgentIDs: [String]?
    /// `PreToolUse` only: the tool and a short target, e.g. "Read NotchPresenter.swift".
    var action: String?
    /// `PreToolUse` and `PostToolUse`: the tool call's ID, which pairs its two events.
    var toolUseID: String?
    /// `PostToolUse` of `Edit`, `MultiEdit` and `Write`: lines the applied edit added and removed (counted, never kept),
    /// and the edited file's name.
    var linesAdded: Int?
    var linesRemoved: Int?
    var editedFile: String?
    /// The extra instance whose hook wrote this event (`--instance <name>`); `nil` for the main one.
    var instance: String?

    /// The counts of an applied edit; `nil` for every other event.
    var lineCounts: LineCounts? {
        guard let linesAdded, let linesRemoved else { return nil }
        // Event files can be edited by hand: no negative counts, and no sum that overflows.
        return LineCounts(added: min(max(linesAdded, 0), LineCounts.maxCount), removed: min(max(linesRemoved, 0), LineCounts.maxCount))
    }
}

/// Lines an edit added and removed.
nonisolated struct LineCounts: Equatable, Hashable, Sendable {
    var added: Int
    var removed: Int

    static let maxCount = 1_000_000_000
}
