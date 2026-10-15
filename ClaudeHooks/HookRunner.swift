import Foundation

/// The logic of `workdeck-hook`, kept here so it is unit-testable from the app's tests.
nonisolated struct HookRunner: Sendable {
    static let maxInputSize = 4 << 20

    let directory: URL
    var readMeta: @Sendable (URL) -> AgentMeta? = { AgentDescriptionReader.meta(at: $0) }
    /// The extra instance this hook belongs to; `nil` for the main one.
    var instance: String?
    /// `--agent codex`: Codex's hook. Its events go to `sessions-codex`, carry the session file and the `codex` PID.
    var isCodex = false
    var codexPID: @Sendable () -> Int32? = { CodexProcess.ancestorPID() }

    static func isCodex(_ arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: "--agent"), arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1] == "codex"
    }

    /// The value of `--instance` when it is a valid instance name; the same rule as `StatusLineRunner.instance(from:)`.
    static func instance(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--instance"), arguments.indices.contains(index + 1) else { return nil }
        let name = arguments[index + 1]
        let allowed = name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        guard (1...20).contains(name.count), allowed, name.first != "-", name != "main" else { return nil }
        return name
    }

    /// Never throws and never prints: Claude Code must not notice this hook.
    func run(stdin: Data, environment: [String: String], now: Date) {
        guard stdin.count <= Self.maxInputSize,
              var payload = HookPayloadFilter.parse(stdin, environment: environment, now: now)
        else { return }
        if !isCodex, payload.event.name == .subagentStart, let transcriptPath = payload.transcriptPath, let agentID = payload.event.agentID {
            let url = AgentDescriptionReader.metaURL(transcriptPath: transcriptPath, sessionID: payload.event.sessionID, agentID: agentID)
            let meta = readMeta(url)
            payload.event.agentDescription = meta?.description
            payload.event.agentModel = meta?.model
            payload.event.agentBackground = meta?.isBackground
            payload.event.agentTranscriptPath = AgentDescriptionReader.transcriptURL(forMeta: url).path
        }
        if isCodex {
            // Only a session file's path is kept, never its content; the app checks where it points.
            if let path = payload.transcriptPath, path.hasSuffix(".jsonl"), path.count <= 512 {
                payload.event.transcriptPath = path
            }
            payload.event.pid = codexPID()
        } else {
            payload.event.instance = instance
        }
        try? HookEventFile.append(payload.event, to: directory)
    }
}
