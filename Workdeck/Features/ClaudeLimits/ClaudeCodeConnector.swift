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

    func connect() throws {
        guard canConnect else { throw ClaudeConnectorError.binaryMissing }
        var settings = try readSettings() ?? Settings(root: [:])

        try file.backUp()
        if let original = settings.root["statusLine"], let command = settings.statusLineCommand, !Self.isWorkdeckCommand(command) {
            let originalJSON = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
            try StatusLineConfig(
                chainedCommand: command,
                originalStatusLineJSON: String(decoding: originalJSON, as: UTF8.self)
            ).write(to: paths.statusLineConfigURL)
        }
        settings.root["statusLine"] = ["type": "command", "command": Self.command(for: binaryPath)]
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
              command != Self.command(for: binaryPath),
              !Self.isTemporaryLocation(binaryPath),
              canConnect
        else { return }
        settings.root["statusLine"] = ["type": "command", "command": Self.command(for: binaryPath)]
        try? write(settings)
    }

    static func isWorkdeckCommand(_ command: String) -> Bool {
        command.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")).hasSuffix(binarySuffix)
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
