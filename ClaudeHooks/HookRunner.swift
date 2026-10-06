import Foundation

/// The logic of `workdeck-hook`, kept here so it is unit-testable from the app's tests.
nonisolated struct HookRunner: Sendable {
    static let maxInputSize = 4 << 20

    let directory: URL
    var readMeta: @Sendable (URL) -> AgentMeta? = { AgentDescriptionReader.meta(at: $0) }

    /// Never throws and never prints: Claude Code must not notice this hook.
    func run(stdin: Data, environment: [String: String], now: Date) {
        guard stdin.count <= Self.maxInputSize,
              var payload = HookPayloadFilter.parse(stdin, environment: environment, now: now)
        else { return }
        if payload.event.name == .subagentStart, let transcriptPath = payload.transcriptPath, let agentID = payload.event.agentID {
            let url = AgentDescriptionReader.metaURL(transcriptPath: transcriptPath, sessionID: payload.event.sessionID, agentID: agentID)
            let meta = readMeta(url)
            payload.event.agentDescription = meta?.description
            payload.event.agentModel = meta?.model
            payload.event.agentBackground = meta?.isBackground
            payload.event.agentTranscriptPath = AgentDescriptionReader.transcriptURL(forMeta: url).path
        }
        try? HookEventFile.append(payload.event, to: directory)
    }
}
