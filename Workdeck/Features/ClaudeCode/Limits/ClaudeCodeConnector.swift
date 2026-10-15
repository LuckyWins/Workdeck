import Foundation

enum ClaudeConnectionStatus: Equatable {
    case connected
    case notConnected
}

enum ClaudeConnectorError: LocalizedError, Equatable {
    case invalidSettings
    case binaryMissing
    /// The file changed after the user reviewed its diff (settings diff spec §2.3).
    case changedSinceReview

    var errorDescription: String? {
        switch self {
        case .invalidSettings: "Fix ~/.claude/settings.json first: it is not valid JSON."
        case .binaryMissing: "The status line command is missing from the app bundle."
        case .changedSinceReview: SettingsReviewText.fileChangedSinceShown
        }
    }

    /// The same problem for an extra instance's file, e.g. "Fix ~/.claude-personal/settings.json first: …".
    static func invalidSettingsMessage(directory: URL) -> String {
        "Fix \((directory.path as NSString).abbreviatingWithTildeInPath)/settings.json first: it is not valid JSON."
    }
}

protocol ClaudeCodeConnecting {
    var status: ClaudeConnectionStatus { get }
    var canConnect: Bool { get }
    var backupPath: String { get }
    /// `reviewed` is the change the user confirmed: the file is written only if it is still as reviewed.
    func connect(reviewed: SettingsChange?) throws
    func disconnect(reviewed: SettingsChange?) throws
    func repairPathIfNeeded()
    /// What `connect()` / `disconnect()` would write, without writing; `nil` when nothing would change.
    func plannedConnect() throws -> SettingsChange?
    func plannedDisconnect() throws -> SettingsChange?
}

extension ClaudeCodeConnecting {
    func connect() throws {
        try connect(reviewed: nil)
    }

    func disconnect() throws {
        try disconnect(reviewed: nil)
    }
}

/// Adds Workdeck's status line command to Claude Code's user settings, and removes it again.
struct ClaudeCodeConnector: ClaudeCodeConnecting {
    static let binarySuffix = "/Contents/Helpers/workdeck-statusline"

    let settingsURL: URL
    let paths: WorkdeckPaths
    let binaryPath: String
    /// The extra instance this connector belongs to; `nil` for the main one.
    var instance: String?

    static func forInstance(_ instance: ClaudeInstance) -> ClaudeCodeConnector {
        ClaudeCodeConnector(
            settingsURL: instance.directory.appending(path: "settings.json"),
            paths: .standard(),
            binaryPath: Bundle.main.bundlePath + binarySuffix,
            instance: instance.isMain ? nil : instance.name
        )
    }

    private var expectedCommand: String {
        Self.command(for: binaryPath, instance: instance)
    }

    private var configURL: URL {
        paths.statusLineConfigURL(for: instance)
    }

    static func standard() -> ClaudeCodeConnector {
        ClaudeCodeConnector(
            settingsURL: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json"),
            paths: .standard(),
            binaryPath: Bundle.main.bundlePath + binarySuffix
        )
    }

    private var file: ClaudeSettingsFile {
        ClaudeSettingsFile(url: settingsURL)
    }

    var backupURL: URL {
        file.backupURL
    }

    var backupPath: String {
        backupURL.path
    }

    var canConnect: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    var status: ClaudeConnectionStatus {
        guard let command = (try? readSettings())?.statusLineCommand, Self.isWorkdeckCommand(command) else {
            return .notConnected
        }
        return .connected
    }

    func connect(reviewed: SettingsChange?) throws {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        let current = try file.readWithData()
        try ClaudeSettingsFile.ensure(current, matches: reviewed)
        var settings = Settings(root: current?.root ?? [:])

        try file.backUp()
        if let original = settings.root["statusLine"], let command = settings.statusLineCommand, !Self.isWorkdeckCommand(command) {
            let originalJSON = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
            try StatusLineConfig(
                chainedCommand: command,
                originalStatusLineJSON: String(decoding: originalJSON, as: UTF8.self)
            ).write(to: configURL)
        }
        settings.root["statusLine"] = ["type": "command", "command": expectedCommand]
        try write(settings)
    }

    func disconnect(reviewed: SettingsChange?) throws {
        let current = try file.readWithData()
        try ClaudeSettingsFile.ensure(current, matches: reviewed)
        if let current, let command = Settings(root: current.root).statusLineCommand, Self.isWorkdeckCommand(command) {
            var settings = Settings(root: current.root)
            if let chained = chainedStatusLine() {
                settings.root["statusLine"] = chained
            } else {
                settings.root.removeValue(forKey: "statusLine")
            }
            try write(settings)
        }
        try? FileManager.default.removeItem(at: configURL)
    }

    func plannedConnect() throws -> SettingsChange? {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        let current = try file.readWithData()
        var settings = Settings(root: current?.root ?? [:])
        let hasOwn = settings.statusLineCommand.map { !Self.isWorkdeckCommand($0) } ?? false
        settings.root["statusLine"] = ["type": "command", "command": expectedCommand]
        var change = try file.change(account: accountName, from: current, to: settings.root)
        change?.hasOwnStatusLine = hasOwn
        return change
    }

    func plannedDisconnect() throws -> SettingsChange? {
        guard let current = try file.readWithData() else { return nil }
        var settings = Settings(root: current.root)
        guard let command = settings.statusLineCommand, Self.isWorkdeckCommand(command) else { return nil }
        let chained = chainedStatusLine()
        if let chained {
            settings.root["statusLine"] = chained
        } else {
            settings.root.removeValue(forKey: "statusLine")
        }
        var change = try file.change(account: accountName, from: current, to: settings.root)
        change?.hasOwnStatusLine = chained != nil
        return change
    }

    private var accountName: String {
        instance ?? ClaudeInstance.mainName
    }

    /// The user's own status line that connecting chained, if any.
    private func chainedStatusLine() -> Any? {
        guard let json = StatusLineConfig.read(from: configURL)?.originalStatusLineJSON else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    /// Points the status line at this app bundle if it was connected from another location.
    func repairPathIfNeeded() {
        guard var settings = try? readSettings(),
              let command = settings.statusLineCommand,
              Self.isWorkdeckCommand(command),
              command != expectedCommand,
              !Self.isTemporaryLocation(binaryPath),
              canConnect
        else { return }
        settings.root["statusLine"] = ["type": "command", "command": expectedCommand]
        try? write(settings)
    }

    static func isWorkdeckCommand(_ command: String) -> Bool {
        executablePath(of: command).hasSuffix(binarySuffix)
    }

    /// The program at the start of a command line, without its arguments; a quoted path may hold spaces.
    static func executablePath(of command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.first == "'" {
            // `command(for:)` writes an apostrophe in the path as '\'' (close, escaped quote, reopen).
            var path = ""
            var rest = Substring(trimmed)
            while rest.first == "'" {
                rest = rest.dropFirst()
                guard let end = rest.firstIndex(of: "'") else { return path + rest }
                path += rest[..<end]
                rest = rest[rest.index(after: end)...]
                guard rest.hasPrefix("\\'") else { break }
                path += "'"
                rest = rest.dropFirst(2)
            }
            return path
        }
        if trimmed.first == "\"", let end = trimmed.dropFirst().firstIndex(of: "\"") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
        }
        return trimmed.components(separatedBy: " ").first ?? trimmed
    }

    /// The quoted command, with ` --instance <name>` for an extra instance.
    static func command(for binaryPath: String, instance: String?) -> String {
        command(for: binaryPath) + (instance.map { " --instance \($0)" } ?? "")
    }

    /// Claude Code runs the command in a shell, so the path is single-quoted.
    static func command(for binaryPath: String) -> String {
        "'" + binaryPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A mounted disk image or an App Translocation path disappears later; never point Claude Code there.
    static func isTemporaryLocation(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    // MARK: - Settings file

    struct Settings {
        var root: [String: Any]

        var statusLineCommand: String? {
            (root["statusLine"] as? [String: Any])?["command"] as? String
        }
    }

    /// `nil` when the file does not exist; throws when it is not a JSON object.
    private func readSettings() throws -> Settings? {
        try file.read().map(Settings.init(root:))
    }

    private func write(_ settings: Settings) throws {
        try file.write(settings.root)
    }
}
