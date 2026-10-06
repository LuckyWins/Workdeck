import Foundation
import OSLog

/// The text Copy Diagnostics puts on the clipboard: a state snapshot and recent log lines. Never content.
enum DiagnosticsReport {
    static func text(
        appVersion: String,
        now: Date,
        settings: ClaudeCodeSettings,
        statusLineConnected: Bool,
        hooksConnected: Bool,
        sessions: [ClaudeSession],
        logLines: [String]
    ) -> String {
        var lines = [
            "Workdeck \(appVersion) — \(ISO8601DateFormatter().string(from: now))",
            "Status line: \(statusLineConnected ? "connected" : "not connected"); usage API: \(settings.fetchFromAPI ? "on" : "off")",
            "Session hooks: \(hooksConnected ? "connected" : "not connected")",
            "Indicator: \(settings.isEnabled ? "on" : "off"); mode: \(settings.mode.title); thresholds: \(settings.thresholds.map { "\($0)%" }.joined(separator: ", "))",
            "Keep awake: \(settings.keepAwakeWhileWorking ? "on" : "off"); finished alerts: \(settings.notifyWhenFinished ? "after \(settings.finishedAfterMinutes)m" : "off"); needs-you alerts: \(settings.notifyWhenNeedsYou ? "on" : "off")",
            "",
            "Sessions (\(sessions.count)):",
        ]
        for session in sessions {
            let agents = session.agents.map { agent in
                [agent.type, (agent.modelID ?? agent.model).map(ModelName.display), agent.isBackground ? "bg" : nil, "\(agent.steps) steps"]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            let agentText = agents.isEmpty ? "no agents" : "\(agents.count) agent\(agents.count == 1 ? "" : "s"): \(agents.joined(separator: "; "))"
            lines.append("  \(SessionChangeLog.label(session)) \(SessionChangeLog.status(session.status)), \(agentText)")
        }
        lines += ["", "Log (last hour):"] + logLines.map { "  \($0)" }
        return lines.joined(separator: "\n")
    }

    /// This process's Workdeck log entries since `date`, as "HH:mm:ss [category] message".
    static func recentLogLines(since date: Date) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: date), matching: NSPredicate(format: "subsystem == %@", WorkdeckLog.subsystem))
        else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries.compactMap { $0 as? OSLogEntryLog }.map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }
    }
}
