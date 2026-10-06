import Foundation

/// The logic of `workdeck-hook`, kept here so it is unit-testable from the app's tests.
nonisolated struct HookRunner: Sendable {
    static let maxInputSize = 4 << 20

    let directory: URL
    var readDescription: @Sendable (URL) -> String? = { AgentDescriptionReader.description(at: $0) }

    /// Never throws and never prints: Claude Code must not notice this hook.
    func run(stdin: Data, environment: [String: String], now: Date) {
        guard stdin.count <= Self.maxInputSize,
              var payload = HookPayloadFilter.parse(stdin, environment: environment, now: now)
        else { return }
        if payload.event.name == .subagentStart, let transcriptPath = payload.transcriptPath, let agentID = payload.event.agentID {
            let url = AgentDescriptionReader.metaURL(transcriptPath: transcriptPath, sessionID: payload.event.sessionID, agentID: agentID)
            payload.event.agentDescription = readDescription(url)
        }
        try? HookEventFile.append(payload.event, to: directory)
    }
}
