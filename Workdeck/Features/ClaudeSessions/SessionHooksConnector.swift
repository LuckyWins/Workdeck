import Foundation

protocol SessionHooksConnecting {
    var status: ClaudeConnectionStatus { get }
    var canConnect: Bool { get }
    func connect() throws
    func disconnect() throws
    func repairPathIfNeeded(addingMissingEvents: Bool)
}

/// Adds Workdeck's hook entries to Claude Code's user settings, and removes them again (spec §5.3).
struct SessionHooksConnector: SessionHooksConnecting {
    static let binarySuffix = "/Contents/Helpers/workdeck-hook"
    static let events = HookEventName.allCases.map(\.rawValue)
    /// Events added after the first version: without them sessions still work (no actions, no compacting),
    /// so a user may remove them and stay connected.
    static let optionalEvents: Set<String> = [HookEventName.preToolUse.rawValue, HookEventName.preCompact.rawValue]
    static let requiredEvents = events.filter { !optionalEvents.contains($0) }

    let file: ClaudeSettingsFile
    let binaryPath: String

    static func standard() -> SessionHooksConnector {
        SessionHooksConnector(file: .standard(), binaryPath: Bundle.main.bundlePath + binarySuffix)
    }

    var canConnect: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    /// Connected when every required event has Workdeck's hook; a partial set is repaired by connecting again.
    var status: ClaudeConnectionStatus {
        guard let hooks = (try? file.read())?["hooks"] as? [String: Any] else { return .notConnected }
        let complete = Self.requiredEvents.allSatisfy { !Self.workdeckCommands(in: hooks[$0]).isEmpty }
        return complete ? .connected : .notConnected
    }

    func connect() throws {
        try install(events: Self.events, backingUp: true)
    }

    func disconnect() throws {
        guard var root = try file.read(), let hooks = root["hooks"] as? [String: Any] else { return }
        let cleaned = Self.removingWorkdeckHooks(from: hooks)
        guard !NSDictionary(dictionary: cleaned).isEqual(to: hooks) else { return }
        if cleaned.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = cleaned
        }
        try file.write(root)
    }

    /// Points the hooks at this app bundle and, once per new Workdeck version, adds events it newly
    /// subscribes to. Events the user removed stay removed otherwise. Repairs keep the existing backup.
    func repairPathIfNeeded(addingMissingEvents: Bool) {
        guard let hooks = (try? file.read())?["hooks"] as? [String: Any] else { return }
        let connected = Self.events.filter { !Self.workdeckCommands(in: hooks[$0]).isEmpty }
        let commands = connected.flatMap { Self.workdeckCommands(in: hooks[$0]) }
        let needsPath = commands.contains { $0 != ClaudeCodeConnector.command(for: binaryPath) }
        let needsEvents = addingMissingEvents && connected.count < Self.events.count
        guard !commands.isEmpty,
              needsPath || needsEvents,
              !ClaudeCodeConnector.isTemporaryLocation(binaryPath)
        else { return }
        try? install(events: needsEvents ? Self.events : connected, backingUp: false)
    }

    private func install(events: [String], backingUp: Bool) throws {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        var root = try file.read() ?? [:]
        if backingUp {
            try file.backUp()
        }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        root["hooks"] = Self.adding(Self.hook(for: binaryPath), to: Self.removingWorkdeckHooks(from: hooks), events: events)
        try file.write(root)
    }

    static func isWorkdeckCommand(_ command: String) -> Bool {
        command.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")).hasSuffix(binarySuffix)
    }

    static func hook(for binaryPath: String) -> [String: Any] {
        ["type": "command", "command": ClaudeCodeConnector.command(for: binaryPath), "async": true, "timeout": 5]
    }

    /// Workdeck's commands among one event's matcher groups.
    static func workdeckCommands(in groups: Any?) -> [String] {
        ((groups as? [[String: Any]]) ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
            .filter(isWorkdeckCommand)
    }

    /// Drops Workdeck's entries, then groups and event arrays that only held them. Everything else stays as it was.
    static func removingWorkdeckHooks(from hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let kept = entries.filter { !(($0["command"] as? String).map(isWorkdeckCommand) ?? false) }
                if kept.count == entries.count {
                    return group
                }
                if kept.isEmpty {
                    return nil
                }
                var copy = group
                copy["hooks"] = kept
                return copy
            }
            if cleaned.isEmpty, !groups.isEmpty {
                result.removeValue(forKey: event)
            } else {
                result[event] = cleaned
            }
        }
        return result
    }

    static func adding(_ hook: [String: Any], to hooks: [String: Any], events: [String] = events) -> [String: Any] {
        var result = hooks
        for event in events {
            var groups = result[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [hook]])
            result[event] = groups
        }
        return result
    }
}
