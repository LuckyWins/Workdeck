import OSLog

/// Workdeck's unified log. Only sanitized values: never prompts, actions, descriptions, or tokens (spec §12.3).
nonisolated enum WorkdeckLog {
    static let subsystem = HelperConstants.appIdentifier
    static let sessions = Logger(subsystem: subsystem, category: "sessions")
    static let alerts = Logger(subsystem: subsystem, category: "alerts")
    static let keepAwake = Logger(subsystem: subsystem, category: "keepAwake")
    static let limits = Logger(subsystem: subsystem, category: "limits")
    static let chats = Logger(subsystem: subsystem, category: "chats")
}
