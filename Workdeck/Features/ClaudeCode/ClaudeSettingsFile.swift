import Foundation

/// Claude Code's user settings file, read and written as a JSON object through a symlink if there is one.
struct ClaudeSettingsFile {
    let url: URL

    static func standard() -> ClaudeSettingsFile {
        ClaudeSettingsFile(url: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json"))
    }

    /// Whether an instance's settings file is the main one, e.g. both are symlinks to one dotfile.
    static func isSameFile(_ url: URL, as other: URL?) -> Bool {
        guard let other else { return false }
        return url.resolvingSymlinksInPath().standardizedFileURL.path == other.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static let sharedSettingsMessage = "Shares settings.json with main"

    var backupURL: URL {
        url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".workdeck-backup")
    }

    /// The real file behind `url`; dotfile managers often make it a symlink, which must survive.
    var targetURL: URL {
        url.resolvingSymlinksInPath()
    }

    /// `nil` when the file does not exist; throws when it is not a JSON object.
    func read() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return nil }
        let data = try Data(contentsOf: targetURL)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeConnectorError.invalidSettings
        }
        return root
    }

    /// Copies the contents, not the link, so the backup is a real snapshot.
    func backUp() throws {
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return }
        try Data(contentsOf: targetURL).write(to: backupURL, options: .atomic)
    }

    func write(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: targetURL, options: .atomic)
    }
}
