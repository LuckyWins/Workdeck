import OSLog

/// Workdeck's unified log. Only sanitized values: never prompts, actions, descriptions, or tokens (spec §12.3).
nonisolated enum WorkdeckLog {
    static let subsystem = HelperConstants.appIdentifier
    static let sessions = Logger(subsystem: subsystem, category: "sessions")
    static let alerts = Logger(subsystem: subsystem, category: "alerts")
    static let keepAwake = Logger(subsystem: subsystem, category: "keepAwake")
    static let limits = Logger(subsystem: subsystem, category: "limits")
    /// Codex's limits from session files and app-server (diagnosing figures that stop updating).
    static let codexLimits = Logger(subsystem: subsystem, category: "codexLimits")
    static let chats = Logger(subsystem: subsystem, category: "chats")
}
