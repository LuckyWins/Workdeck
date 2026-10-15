import Foundation

/// Adds `workdeck-hook --agent codex` to Codex's `~/.codex/hooks.json`, and removes it again (Codex spec §3.3). The
/// file has the same shape as Claude Code's settings hooks, so Claude's helpers edit it.
struct CodexHooksConnector: SessionHooksConnecting {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SubagentStart", "SubagentStop", "Interrupt", "SessionEnd"]
    static let account = "codex"

    let file: ClaudeSettingsFile
    let binaryPath: String
    var isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    static func standard() -> CodexHooksConnector {
        CodexHooksConnector(
            file: ClaudeSettingsFile(url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/hooks.json")),
            binaryPath: Bundle.main.bundlePath + SessionHooksConnector.binarySuffix
        )
    }

    var canConnect: Bool {
        isExecutable(binaryPath)
    }

    var status: ClaudeConnectionStatus {
        guard let hooks = (try? file.read())?["hooks"] as? [String: Any] else { return .notConnected }
        let complete = Self.events.allSatisfy { !SessionHooksConnector.workdeckCommands(in: hooks[$0]).isEmpty }
        return complete ? .connected : .notConnected
    }

    /// Codex runs the command in a shell; the hook must answer at once, so no `async` key Codex might not know.
    static func hook(for binaryPath: String) -> [String: Any] {
        ["type": "command", "command": ClaudeCodeConnector.command(for: binaryPath) + " --agent codex", "timeout": 5]
    }

    func connect(reviewed: SettingsChange?) throws {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        let current = try file.readWithData()
        try ClaudeSettingsFile.ensure(current, matches: reviewed)
        try file.backUp()
        try file.write(installing(in: current?.root ?? [:]))
    }

    func disconnect(reviewed: SettingsChange?) throws {
        let current = try file.readWithData()
        try ClaudeSettingsFile.ensure(current, matches: reviewed)
        guard let current, let cleaned = SessionHooksConnector.uninstalling(from: current.root) else { return }
        try file.write(cleaned)
    }

    func plannedConnect() throws -> SettingsChange? {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        let current = try file.readWithData()
        return try file.change(account: Self.account, from: current, to: installing(in: current?.root ?? [:]))
    }

    func plannedDisconnect() throws -> SettingsChange? {
        guard let current = try file.readWithData(), let after = SessionHooksConnector.uninstalling(from: current.root) else { return nil }
        return try file.change(account: Self.account, from: current, to: after)
    }

    /// Points the hooks at this app bundle after Workdeck moved; events the user removed stay removed.
    func repairPathIfNeeded(addingMissingEvents: Bool) {
        guard let root = try? file.read(), let hooks = root["hooks"] as? [String: Any] else { return }
        let connected = Self.events.filter { !SessionHooksConnector.workdeckCommands(in: hooks[$0]).isEmpty }
        let commands = connected.flatMap { SessionHooksConnector.workdeckCommands(in: hooks[$0]) }
        let wanted = Self.hook(for: binaryPath)["command"] as? String
        guard !commands.isEmpty, commands.contains(where: { $0 != wanted }), !ClaudeCodeConnector.isTemporaryLocation(binaryPath) else { return }
        try? file.write(installing(in: root, events: addingMissingEvents ? Self.events : connected))
    }

    private func installing(in root: [String: Any], events: [String] = events) -> [String: Any] {
        var root = root
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        root["hooks"] = SessionHooksConnector.adding(Self.hook(for: binaryPath), to: SessionHooksConnector.removingWorkdeckHooks(from: hooks), events: events)
        return root
    }
}
