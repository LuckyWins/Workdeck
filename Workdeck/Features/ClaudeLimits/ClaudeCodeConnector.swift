import Foundation

enum ClaudeConnectionStatus: Equatable {
    case connected
    case notConnected
}

enum ClaudeConnectorError: LocalizedError, Equatable {
    case invalidSettings
    case binaryMissing

    var errorDescription: String? {
        switch self {
        case .invalidSettings: "Fix ~/.claude/settings.json first: it is not valid JSON."
        case .binaryMissing: "The status line command is missing from the app bundle."
        }
    }
}

protocol ClaudeCodeConnecting {
    var status: ClaudeConnectionStatus { get }
    var canConnect: Bool { get }
    var backupPath: String { get }
    func connect() throws
    func disconnect() throws
    func repairPathIfNeeded()
}

/// Adds Workdeck's status line command to Claude Code's user settings, and removes it again.
struct ClaudeCodeConnector: ClaudeCodeConnecting {
    static let binarySuffix = "/Contents/Helpers/workdeck-statusline"

    let settingsURL: URL
    let paths: WorkdeckPaths
    let binaryPath: String

    static func standard() -> ClaudeCodeConnector {
        ClaudeCodeConnector(
            settingsURL: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json"),
            paths: .standard(),
            binaryPath: Bundle.main.bundlePath + binarySuffix
        )
    }

    var backupURL: URL {
        settingsURL.deletingLastPathComponent().appending(path: settingsURL.lastPathComponent + ".workdeck-backup")
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

    func connect() throws {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        var settings = try readSettings() ?? Settings(root: [:])

        if FileManager.default.fileExists(atPath: settingsURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.copyItem(at: settingsURL, to: backupURL)
        }
        if let original = settings.root["statusLine"], let command = settings.statusLineCommand, !Self.isWorkdeckCommand(command) {
            let originalJSON = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
            try StatusLineConfig(
                chainedCommand: command,
                originalStatusLineJSON: String(decoding: originalJSON, as: UTF8.self)
            ).write(to: paths.statusLineConfigURL)
        }
        settings.root["statusLine"] = ["type": "command", "command": binaryPath]
        try write(settings)
    }

    func disconnect() throws {
        if var settings = try readSettings(), let command = settings.statusLineCommand, Self.isWorkdeckCommand(command) {
            let config = StatusLineConfig.read(from: paths.statusLineConfigURL)
            if let json = config?.originalStatusLineJSON,
               let original = try? JSONSerialization.jsonObject(with: Data(json.utf8)) {
                settings.root["statusLine"] = original
            } else {
                settings.root.removeValue(forKey: "statusLine")
            }
            try write(settings)
        }
        try? FileManager.default.removeItem(at: paths.statusLineConfigURL)
    }

    /// Points the status line at this app bundle if it was connected from another location.
    func repairPathIfNeeded() {
        guard var settings = try? readSettings(),
              let command = settings.statusLineCommand,
              Self.isWorkdeckCommand(command),
              command != binaryPath,
              canConnect
        else { return }
        settings.root["statusLine"] = ["type": "command", "command": binaryPath]
        try? write(settings)
    }

    static func isWorkdeckCommand(_ command: String) -> Bool {
        command.hasSuffix(binarySuffix)
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
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let data = try Data(contentsOf: settingsURL)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeConnectorError.invalidSettings
        }
        return Settings(root: root)
    }

    private func write(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings.root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }
}
