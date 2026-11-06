import Foundation

/// The agents a note can be handed to.
nonisolated enum AgentKindChoice: String, Codable, Sendable {
    case claude
    case codex
}

/// Where ⌘↩ sends a note: the agent, for Claude Code its instance, and the folder Terminal starts in (quick notes
/// spec §5.3). Remembered per Reminders list; it holds names and a path, never any text of a note.
nonisolated struct AgentDestination: Codable, Equatable, Sendable {
    var agent: AgentKindChoice
    /// The Claude Code instance's name; nil for Codex (and for a Claude choice that never named one: the main instance).
    var instance: String?
    var folder: String?

    /// What the user sees: "Claude · main", "Claude · work", "Codex".
    var label: String {
        switch agent {
        case .claude: "Claude · \(instance ?? ClaudeInstance.mainName)"
        case .codex: "Codex"
        }
    }

    /// Claude Code on the main instance, no folder yet.
    static let standard = AgentDestination(agent: .claude, instance: ClaudeInstance.mainName, folder: nil)
}
