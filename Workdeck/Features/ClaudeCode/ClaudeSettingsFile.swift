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
        try readWithData()?.root
    }

    /// The JSON object and the bytes it was read from; `nil` when the file does not exist.
    func readWithData() throws -> (root: [String: Any], data: Data)? {
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return nil }
        let data = try Data(contentsOf: targetURL)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeConnectorError.invalidSettings
        }
        return (root, data)
    }

    /// How Workdeck writes the file: sorted keys, indented, slashes unescaped.
    static func formatted(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    func write(_ root: [String: Any]) throws {
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.formatted(root).write(to: targetURL, options: .atomic)
    }

    /// The change from the file as read (`nil` when missing) to `after`, both in Workdeck's formatting (settings
    /// diff spec §3.3); `nil` when the JSON stays the same.
    func change(account: String, from current: (root: [String: Any], data: Data)?, to after: [String: Any]) throws -> SettingsChange? {
        let before = try current.map { try Self.formatted($0.root) } ?? Data()
        let written = try Self.formatted(after)
        guard written != before else { return nil }
        return SettingsChange(
            account: account,
            url: url,
            original: current?.data,
            before: String(decoding: before, as: UTF8.self),
            after: String(decoding: written, as: UTF8.self),
            isReformatted: current.map { $0.data != before } ?? false
        )
    }

    /// Refuses to write over a file that is no longer what the user reviewed (settings diff spec §2.3); a write
    /// without a review goes ahead.
    static func ensure(_ current: (root: [String: Any], data: Data)?, matches reviewed: SettingsChange?) throws {
        guard let reviewed, current?.data != reviewed.original else { return }
        throw ClaudeConnectorError.changedSinceReview
    }

    /// Copies the contents, not the link, so the backup is a real snapshot.
    func backUp() throws {
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return }
        try Data(contentsOf: targetURL).write(to: backupURL, options: .atomic)
    }
}
