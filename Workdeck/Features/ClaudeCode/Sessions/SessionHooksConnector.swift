import Foundation

protocol SessionHooksConnecting {
    var status: ClaudeConnectionStatus { get }
    var canConnect: Bool { get }
    /// `reviewed` is the change the user confirmed: the file is written only if it is still as reviewed.
    func connect(reviewed: SettingsChange?) throws
    func disconnect(reviewed: SettingsChange?) throws
    func repairPathIfNeeded(addingMissingEvents: Bool)
    /// What `connect()` / `disconnect()` would write, without writing; `nil` when nothing would change.
    func plannedConnect() throws -> SettingsChange?
    func plannedDisconnect() throws -> SettingsChange?
}

extension SessionHooksConnecting {
    func connect() throws {
        try connect(reviewed: nil)
    }

    func disconnect() throws {
        try disconnect(reviewed: nil)
    }
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
    /// The extra instance this connector belongs to; `nil` for the main one.
    var instance: String?

    static func forInstance(_ instance: ClaudeInstance) -> SessionHooksConnector {
        SessionHooksConnector(
            file: ClaudeSettingsFile(url: instance.directory.appending(path: "settings.json")),
            binaryPath: Bundle.main.bundlePath + binarySuffix,
            instance: instance.isMain ? nil : instance.name
        )
    }

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

    func connect(reviewed: SettingsChange?) throws {
        try install(events: Self.events, backingUp: true, reviewed: reviewed)
    }

    func disconnect(reviewed: SettingsChange?) throws {
        let current = try file.readWithData()
        try ClaudeSettingsFile.ensure(current, matches: reviewed)
        guard let current, let cleaned = Self.uninstalling(from: current.root) else { return }
        try file.write(cleaned)
    }

    func plannedConnect() throws -> SettingsChange? {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        let current = try file.readWithData()
        return try file.change(account: instance ?? ClaudeInstance.mainName, from: current, to: installing(Self.events, in: current?.root ?? [:]))
    }

    func plannedDisconnect() throws -> SettingsChange? {
        guard let current = try file.readWithData(), let after = Self.uninstalling(from: current.root) else { return nil }
        return try file.change(account: instance ?? ClaudeInstance.mainName, from: current, to: after)
    }

    private func installing(_ events: [String], in root: [String: Any]) -> [String: Any] {
        var root = root
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        root["hooks"] = Self.adding(Self.hook(for: binaryPath, instance: instance), to: Self.removingWorkdeckHooks(from: hooks), events: events)
        return root
    }

    /// The settings without Workdeck's hooks; `nil` when there are none.
    static func uninstalling(from root: [String: Any]) -> [String: Any]? {
        guard let hooks = root["hooks"] as? [String: Any] else { return nil }
        let cleaned = removingWorkdeckHooks(from: hooks)
        guard !NSDictionary(dictionary: cleaned).isEqual(to: hooks) else { return nil }
        var root = root
        if cleaned.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = cleaned
        }
        return root
    }

    /// Points the hooks at this app bundle and, once per new Workdeck version, adds events it newly
    /// subscribes to. Events the user removed stay removed otherwise. Repairs keep the existing backup.
    func repairPathIfNeeded(addingMissingEvents: Bool) {
        guard let hooks = (try? file.read())?["hooks"] as? [String: Any] else { return }
        let connected = Self.events.filter { !Self.workdeckCommands(in: hooks[$0]).isEmpty }
        let commands = connected.flatMap { Self.workdeckCommands(in: hooks[$0]) }
        let needsPath = commands.contains { $0 != ClaudeCodeConnector.command(for: binaryPath, instance: instance) }
        let needsEvents = addingMissingEvents && connected.count < Self.events.count
        guard !commands.isEmpty,
              needsPath || needsEvents,
              !ClaudeCodeConnector.isTemporaryLocation(binaryPath)
        else { return }
        try? install(events: needsEvents ? Self.events : connected, backingUp: false)
    }

    private func install(events: [String], backingUp: Bool, reviewed: SettingsChange? = nil) throws {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        let current = try file.readWithData()
        try ClaudeSettingsFile.ensure(current, matches: reviewed)
        let root = current?.root ?? [:]
        if backingUp {
            try file.backUp()
        }
        try file.write(installing(events, in: root))
    }

    static func isWorkdeckCommand(_ command: String) -> Bool {
        ClaudeCodeConnector.executablePath(of: command).hasSuffix(binarySuffix)
    }

    static func hook(for binaryPath: String, instance: String? = nil) -> [String: Any] {
        ["type": "command", "command": ClaudeCodeConnector.command(for: binaryPath, instance: instance), "async": true, "timeout": 5]
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
